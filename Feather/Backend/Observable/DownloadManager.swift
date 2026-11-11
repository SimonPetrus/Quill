//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit
import BackgroundTasks
import NimbleExtensions
import OSLog

class Download: Identifiable, @unchecked Sendable {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	/// Smoothed transfer speed, updated about twice per second while bytes arrive.
	@Published var bytesPerSecond: Double = 0.0

	// Throttling / speed bookkeeping. Touched only on the URLSession delegate queue (serial).
	fileprivate var _lastReportTime: CFAbsoluteTime = 0
	fileprivate var _speedTaskIdentifier: Int = -1
	fileprivate var _speedWindowStart: CFAbsoluteTime = 0
	fileprivate var _speedWindowBytes: Int64 = 0
	fileprivate var _smoothedSpeed: Double = 0
	// Automatic resume attempts after a network failure. Touched only on the main thread.
	fileprivate var _retryCount: Int = 0

	var overallProgress: Double {
		onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}
	
	var task: URLSessionDownloadTask?
	var resumeData: Data?
	
	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	var sourceProvenance: SourceAppProvenance?
	
	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false,
		sourceProvenance: SourceAppProvenance? = nil
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.sourceProvenance = sourceProvenance
		self.fileName = url.lastPathComponent
	}
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()
	
	@Published var downloads: [Download] = []
	
	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}
	
	private var _session: URLSession!

	/// Dedicated serial queue for URLSession delegate callbacks (never the main queue).
	private let _delegateQueue: OperationQueue = {
		let queue = OperationQueue()
		queue.name = "Quill.DownloadManager.delegate"
		queue.maxConcurrentOperationCount = 1
		queue.qualityOfService = .userInitiated
		return queue
	}()

	/// Task -> download lookup that is safe to read from the delegate queue
	/// (`downloads` itself is only mutated on the main thread).
	private let _taskLock = NSLock()
	private var _tasks: [Int: Download] = [:]

	/// Progress is published to the UI at most this often (10 Hz).
	private static let _progressInterval: CFAbsoluteTime = 0.1
	/// Speed is measured over windows of this length.
	private static let _speedWindow: CFAbsoluteTime = 0.5
	/// Automatic resume attempts (with resume data) before a failed download is dropped.
	private static let _maxRetries = 3

	private func _register(_ task: URLSessionDownloadTask, for download: Download) {
		_taskLock.lock()
		_tasks[task.taskIdentifier] = download
		_taskLock.unlock()
	}

	private func _unregister(_ task: URLSessionTask) {
		_taskLock.lock()
		_tasks.removeValue(forKey: task.taskIdentifier)
		_taskLock.unlock()
	}

	#if !targetEnvironment(macCatalyst)
	private func _updateBackgroundAudioState() {
		if #unavailable(iOS 26.0){
			if !downloads.isEmpty {
				BackgroundAudioManager.shared.start()
			} else  {
				BackgroundAudioManager.shared.stop()
			}
		}
	}
	#endif
	
	/// Import error waiting for a presenter (e.g. the app was in the background when it failed).
	static var pendingImportError: String?
	
	/// Shows the pending import error only while the app is active and a presenter exists;
	/// otherwise it is kept and retried on the next activation. While active but without a usable
	/// presenter (window not key yet on a cold launch, a sheet or alert still animating), it retries
	/// shortly instead of waiting for the next activation.
	func presentPendingImportErrorIfPossible(attempt: Int = 0) {
		DispatchQueue.main.async {
			guard
				DownloadManager.pendingImportError != nil,
				UIApplication.shared.applicationState == .active
			else { return }
			guard
				let message = DownloadManager.pendingImportError,
				let presenter = UIApplication.topViewController(),
				presenter.viewIfLoaded?.window != nil,
				!presenter.isBeingPresented,
				!presenter.isBeingDismissed
			else {
				if attempt < 20 {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
						self.presentPendingImportErrorIfPossible(attempt: attempt + 1)
					}
				}
				return
			}
			DownloadManager.pendingImportError = nil
			IncomingLog.notice("Showing import error alert")
			UIAlertController.showAlertWithOk(presenter, title: .localized("Import Failed"), message: message)
		}
	}
	
	/// Removes leftover download folders (older than 24h) from the app's own temp area.
	private static func _cleanStaleDownloads() {
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appendingPathComponent("QuillDownloads", isDirectory: true)
		guard let items = try? fm.contentsOfDirectory(
			at: dir,
			includingPropertiesForKeys: [.contentModificationDateKey]
		) else { return }
		let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
		for item in items {
			let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
			if let date, date < cutoff {
				try? fm.removeItem(at: item)
			}
		}
	}
	
	override init() {
		super.init()
		DispatchQueue.global(qos: .utility).async { DownloadManager._cleanStaleDownloads() }
		let configuration = URLSessionConfiguration.default
		// User-initiated transfers the user is waiting for.
		configuration.networkServiceType = .responsiveData
		configuration.allowsCellularAccess = true
		configuration.allowsExpensiveNetworkAccess = true
		configuration.allowsConstrainedNetworkAccess = true
		configuration.httpMaximumConnectionsPerHost = 6
		// IPAs are far too large for URLCache; skip the cache entirely.
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: _delegateQueue)
	}
	
	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		sourceProvenance: SourceAppProvenance? = nil
	) -> Download {
		let requestHasSourceProvenance = sourceProvenance != nil
		if let existingDownload = downloads.first(where: {
			$0.url == url && ($0.sourceProvenance != nil) == requestHasSourceProvenance
		}) {
			resumeDownload(existingDownload)
			return existingDownload
		}
		
		let download = Download(id: id, url: url, sourceProvenance: sourceProvenance)
		
		let task = _session.downloadTask(with: url)
		download.task = task
		_register(task, for: download)
		task.resume()

		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
		} else {
			_updateBackgroundAudioState()
		}
		#endif
		
		return download
	}
	
	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif
		
		return download
	}
	
	func resumeDownload(_ download: Download) {
		// Never start a second transfer for a download that is still active:
		// a parallel duplicate task would split the bandwidth and its bytes would be thrown away.
		if let current = download.task {
			switch current.state {
			case .running:
				return
			case .suspended:
				current.resume()
				return
			default:
				break
			}
		}

		if let resumeData = download.resumeData {
			download.resumeData = nil
			let task = _session.downloadTask(withResumeData: resumeData)
			download.task = task
			_register(task, for: download)
			task.resume()
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		} else if let url = download.task?.originalRequest?.url {
			let task = _session.downloadTask(with: url)
			download.task = task
			_register(task, for: download)
			task.resume()
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		}
	}
	
	func cancelDownload(_ download: Download) {
		download.task?.cancel()
		
		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()

			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			}
			#endif
		}
	}
	
	func isManualDownload(_ string: String) -> Bool {
		return string.contains("QuillManualDownload")
	}
	
	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}
	
	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}
	
	/// Thread-safe; called from the delegate queue.
	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		_taskLock.lock()
		defer { _taskLock.unlock() }
		return _tasks[task.taskIdentifier]
	}
}

extension DownloadManager: URLSessionDownloadDelegate {
	
	func handlePachageFile(url: URL, dl: Download, completion: ((Error?) -> Void)? = nil) throws {
		FR.handlePackageFile(url, download: dl) { err in
			completion?(err)
			if let err {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)
				DownloadManager.pendingImportError = err.localizedDescription
				DownloadManager.shared.presentPendingImportErrorIfPossible()
			}
			
			DispatchQueue.main.async {
				if let index = DownloadManager.shared.getDownloadIndex(by: dl.id) {
					DownloadManager.shared.downloads.remove(at: index)
					
					#if !targetEnvironment(macCatalyst)
					if #available(iOS 26.0, *) {
						BackgroundTaskManager.shared.updateProgress(for: dl.id, progress: 1.0)
					}
					
					self._updateBackgroundAudioState()
					#endif
				}
			}
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
		
		let tempDirectory = FileManager.default.temporaryDirectory
		let customTempDir = tempDirectory.appendingPathComponent("QuillDownloads", isDirectory: true)
		
		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			
			// Use the server-suggested filename if available, otherwise fallback
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			// Unique sub folder per download: two downloads with the same file name must never share a path.
			let downloadDir = customTempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectoryIfNeeded(at: downloadDir)
			let destinationURL = downloadDir.appendingPathComponent(suggestedFileName)
			
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			
			try handlePachageFile(url: destinationURL, dl: download)
		} catch {
			print("Error handling downloaded file: \(error.localizedDescription)")
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let download = getDownloadTask(by: downloadTask) else { return }

		// This callback fires for every network chunk (often thousands of times per second on a
		// fast connection). Do only cheap bookkeeping here and publish to the main thread at most
		// 10 times per second, otherwise the main thread is flooded with SwiftUI updates.
		let now = CFAbsoluteTimeGetCurrent()

		if download._speedTaskIdentifier != downloadTask.taskIdentifier {
			// New (or resumed) task: start a fresh speed window.
			download._speedTaskIdentifier = downloadTask.taskIdentifier
			download._speedWindowStart = now
			download._speedWindowBytes = 0
			download._smoothedSpeed = 0
		}
		download._speedWindowBytes += bytesWritten

		var newSpeed: Double?
		let windowElapsed = now - download._speedWindowStart
		if windowElapsed >= Self._speedWindow {
			let instant = Double(download._speedWindowBytes) / windowElapsed
			download._smoothedSpeed = download._smoothedSpeed == 0
				? instant
				: (0.6 * instant) + (0.4 * download._smoothedSpeed)
			download._speedWindowStart = now
			download._speedWindowBytes = 0
			newSpeed = download._smoothedSpeed
		}

		let isComplete = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
		guard
			isComplete
			|| newSpeed != nil
			|| now - download._lastReportTime >= Self._progressInterval
		else {
			return
		}
		download._lastReportTime = now

		let progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0

		DispatchQueue.main.async {
			download.progress = progress
			if totalBytesWritten > download.bytesDownloaded {
				// New bytes arrived: the connection works again, so allow fresh resume attempts.
				download._retryCount = 0
			}
			download.bytesDownloaded = totalBytesWritten
			if download.totalBytes != totalBytesExpectedToWrite {
				download.totalBytes = totalBytesExpectedToWrite
			}
			if let newSpeed {
				download.bytesPerSecond = newSpeed
			}

			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
			}
			#endif
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		let downloadTask = task as? URLSessionDownloadTask
		let download = downloadTask.flatMap { getDownloadTask(by: $0) }
		_unregister(task)

		guard let error, let downloadTask, let download else { return }

		let nsError = error as NSError
		let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
		let isCancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled

		DispatchQueue.main.async {
			// Ignore stale tasks and downloads that were cancelled/removed in the meantime.
			guard
				download.task == downloadTask,
				let index = self.getDownloadIndex(by: download.id)
			else {
				return
			}

			// Transient network failure with resume data: continue from where it stopped
			// instead of dropping the download and making the user start from zero.
			if !isCancelled, let resumeData, download._retryCount < Self._maxRetries {
				download._retryCount += 1
				download.resumeData = resumeData
				let delay = Double(download._retryCount)
				DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
					guard self.getDownloadIndex(by: download.id) != nil else { return }
					self.resumeDownload(download)
				}
				return
			}

			self.downloads.remove(at: index)

			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			}
			self._updateBackgroundAudioState()
			#endif
		}
	}
}
