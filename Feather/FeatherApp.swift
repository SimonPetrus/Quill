//
//  FeatherApp.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import Nuke
import NimbleViews
import IDeviceSwift
import OSLog

@main
struct QuillApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	
	/// Evaluated while the App struct is created, before the stored properties below that touch
	/// storage (initializers run in declaration order): moves pre-rename data first.
	private let _legacyMigration: Void = LegacyMigration.runIfNeeded()
	/// Registers UserDefaults defaults (server type = Semi Local) before any view reads them.
	private let _registerDefaults: Void = ServerInstaller.registerDefaults()
	
	let heartbeat = HeartbeatManager.shared
	
	@StateObject var downloadManager = DownloadManager.shared
	let storage = Storage.shared
	@State private var _pendingBackup: PendingBackup?
	@Environment(\.scenePhase) private var _scenePhase
	/// Set once the root view is on screen; incoming URLs wait for it (and for an active app).
	@State private var _isRootReady = false

	var body: some Scene {
		WindowGroup {
			VStack {
				DownloadHeaderView(downloadManager: downloadManager)
					.transition(.move(edge: .top).combined(with: .opacity))
				VariedTabbarView()
					.environment(\.managedObjectContext, storage.context)
					.onOpenURL { url in
						IncomingURLRouter.shared.enqueue(url, origin: .onOpenURL)
					}
					.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
						IncomingURLRouter.shared.handle(activity, via: "swiftui")
					}
					.transition(.move(edge: .top).combined(with: .opacity))
			}
			.onReceive(IncomingURLRouter.shared.$pendingCount) { count in
				if count > 0 { _drainIncomingURLs() }
			}
			.onChange(of: _scenePhase) { phase in
				if phase == .active { _drainIncomingURLs() }
			}
			.sheet(item: $_pendingBackup) { pending in
				NBNavigationView(.localized("Backup & Restore"), displayMode: .inline) {
					BackupView(initialURL: pending.url)
						.toolbar { NBToolbarButton(role: .close) }
				}
			}
			.animation(.smooth, value: downloadManager.manualDownloads.description)
			.onReceive(NotificationCenter.default.publisher(for: .heartbeatInvalidHost)) { _ in
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(
						title: "InvalidHostID",
						message: .localized("Your pairing file is invalid and is incompatible with your device, please import a valid pairing file.")
					)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
				_showStartupNoticeIfPossible()
				NotificationManager.shared.reschedule()
				DownloadManager.shared.presentPendingImportErrorIfPossible()
				// Share-sheet copies can arrive in the Inbox without any URL delivery.
				IncomingInboxScanner.scan(reason: "active")
				_drainIncomingURLs()
				// Delayed so a startup notice shown just above wins; the update alert then waits for the next activation.
				DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
					SelfUpdateManager.shared.presentPendingIfPossible()
				}
			}
			// dear god help me
			.onAppear {
				if let style = UIUserInterfaceStyle(rawValue: UserDefaults.standard.integer(forKey: "Quill.userInterfaceStyle")) {
					UIApplication.topViewController()?.view.window?.overrideUserInterfaceStyle = style
				}
				
				_showStartupNoticeIfPossible()
				Storage.shared.removeLegacyUpstreamSourceIfNeeded()
				Storage.shared.addOwnSourceIfNeeded()
				SelfUpdateManager.shared.autoCheckIfNeeded()
				
				UIApplication.topViewController()?.view.window?.tintColor = UIColor(Color(hex: UserDefaults.standard.string(forKey: "Quill.userTintColor") ?? "#848ef9"))

				_isRootReady = true
				IncomingInboxScanner.scan(reason: "launch")
				_drainIncomingURLs()
			}
		}
	}

	/// Hands queued incoming URLs to `_handleURL` once the root view is on screen and the app is
	/// active; otherwise they stay queued and the next trigger (root appeared, scene became
	/// active, new URL queued) tries again.
	private func _drainIncomingURLs(attempt: Int = 0) {
		DispatchQueue.main.async {
			guard IncomingURLRouter.shared.pendingCount > 0 else { return }
			guard _isRootReady, UIApplication.shared.applicationState == .active else {
				IncomingLog.notice("Waiting for UI: rootReady=\(_isRootReady) appState=\(UIApplication.shared.applicationState.rawValue)")
				return
			}
			// Root view is up but the window may not be key yet: retry shortly instead of
			// waiting for the next activation.
			guard UIApplication.topViewController() != nil else {
				if attempt < 10 {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
						_drainIncomingURLs(attempt: attempt + 1)
					}
				} else {
					IncomingLog.error("No presenter for incoming URL; kept for next activation")
				}
				return
			}
			for url in IncomingURLRouter.shared.takeAll() {
				_handleURL(url)
			}
		}
	}

	/// Shows the pending storage notice only when a presenter exists; otherwise keeps it for the next
	/// time the app becomes active. Cleared only after it was actually presented.
	private func _showStartupNoticeIfPossible() {
		guard let notice = Storage.startupNotice else { return }
		DispatchQueue.main.async {
			guard
				Storage.startupNotice != nil,
				let presenter = UIApplication.topViewController()
			else { return }
			Storage.startupNotice = nil
			UIAlertController.showAlertWithOk(presenter, title: .localized("Error"), message: notice)
		}
	}
	
	private func _handleURL(_ url: URL) {
		if url.scheme == "quill" {
			IncomingLog.notice("Handling URL: quill link host=\(url.host ?? "-")")
			/// quill://import-certificate?p12=<base64>&mobileprovision=<base64>&password=<base64>
			if url.host == "import-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
					let queryItems = components.queryItems
				else {
					return
				}
				
				func queryValue(_ name: String) -> String? {
					queryItems.first(where: { $0.name == name })?.value?.removingPercentEncoding
				}
				
				guard
					let p12Base64 = queryValue("p12"),
					let provisionBase64 = queryValue("mobileprovision"),
					let passwordBase64 = queryValue("password"),
					let passwordData = Data(base64Encoded: passwordBase64),
					let password = String(data: passwordData, encoding: .utf8)
				else {
					return
				}
				
				let generator = UINotificationFeedbackGenerator()
				generator.prepare()
				
				guard
					let p12URL = FileManager.default.decodeAndWrite(base64: p12Base64, pathComponent: ".p12"),
					let provisionURL = FileManager.default.decodeAndWrite(base64: provisionBase64, pathComponent: ".mobileprovision"),
					FR.checkPasswordForCertificate(for: p12URL, with: password, using: provisionURL)
				else {
					generator.notificationOccurred(.error)
					return
				}
				
				CertificatePairValidator.check(
					p12URL: p12URL,
					password: password,
					provisionURL: provisionURL,
					continueTitle: .localized("Import Anyway"),
					proceed: {
						FR.handleCertificateFiles(
							p12URL: p12URL,
							provisionURL: provisionURL,
							p12Password: password
						) { error in
							if let error = error {
								UIAlertController.showAlertWithOk(title: .localized("Error"), message: ErrorExplainer.message(for: error))
							} else {
								generator.notificationOccurred(.success)
							}
						}
					},
					cancel: {
						generator.notificationOccurred(.error)
					}
				)

				return
			}
			/// quill://export-certificate?callback_template=<template>
			/// ?callback_template=: This is how we callback to the application requesting the certificate, this will be a url scheme
			/// 	example: livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29
			/// 	decoded: livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)
			/// $(BASE64_CERT) and $(PASSWORD) must be presenting in the callback template so we can replace them with the proper content
			if url.host == "export-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				else {
					return
				}
				
				let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
				guard let callbackTemplate = queryItems["callback_template"]?.removingPercentEncoding else { return }
				
				FR.exportCertificateAndOpenUrl(using: callbackTemplate)
			}
			/// quill://source/<url>
			if let fullPath = url.validatedScheme(after: "/source/") {
				FR.handleSource(fullPath) { }
			}
			/// quill://install/<url.ipa>
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath)
			{
				UIAlertController.showAlertWithCancel(
					title: .localized("Install"),
					message: .localized("Do you want to download and install this file?") + "\n\n\(downloadURL)",
					actions: [
						UIAlertAction(title: .localized("Install"), style: .default) { _ in
							_ = DownloadManager.shared.startDownload(from: downloadURL)
						}
					]
				)
			}
		} else {
			let ext = url.pathExtension.lowercased()
			if ext == "quillbackup" {
				IncomingLog.notice("Handling URL: backup restore")
				if IncomingURLRouter.isOwnInboxCopy(url) {
					// Move the system Inbox copy out first, so a cancelled restore does not reappear on
					// every launch. If that fails the copy is deleted and an error is shown instead.
					guard let moved = Self._moveOutOfInbox(url) else { return }
					_pendingBackup = PendingBackup(url: moved)
				} else {
					_pendingBackup = PendingBackup(url: url)
				}
				return
			}
			if IncomingPackageImporter.canHandle(url) {
				IncomingLog.notice("Handling URL: package import ext=\(ext)")
				IncomingPackageImporter.handle(url)
				return
			}
			// Never ignore a shared file silently.
			IncomingLog.error("Unsupported URL: scheme=\(url.scheme ?? "-") ext=\(ext)")
			if url.isFileURL {
				DownloadManager.pendingImportError = .localized("This file type is not supported. Share an .ipa or .tipa file.")
				DownloadManager.shared.presentPendingImportErrorIfPossible()
				// A system Inbox copy is ours to delete; otherwise the Inbox scan would find it again on every launch.
				if IncomingURLRouter.isOwnInboxCopy(url) {
					try? FileManager.default.removeItem(at: url)
				}
			}
		}
	}
	
	/// Moves a system Inbox copy into `tmp/QuillIncoming/<UUID>/` (cleared on the next launch).
	/// Returns nil for URLs outside our own Inbox folders (never touched) and when the move fails;
	/// a failed move deletes the Inbox copy (the original stays in the sharing app) and shows an
	/// error, so the same copy is not found again on every launch.
	private static func _moveOutOfInbox(_ url: URL) -> URL? {
		guard IncomingURLRouter.isOwnInboxCopy(url) else { return nil }
		let fileManager = FileManager.default
		let folder = fileManager.temporaryDirectory
			.appendingPathComponent("QuillIncoming", isDirectory: true)
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		do {
			try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
			let destination = folder.appendingPathComponent(url.lastPathComponent)
			try fileManager.moveItem(at: url, to: destination)
			return destination
		} catch {
			let nsError = error as NSError
			IncomingLog.error("Moving backup out of Inbox failed: domain=\(nsError.domain) code=\(nsError.code)")
			try? fileManager.removeItem(at: folder)
			try? fileManager.removeItem(at: url)
			DownloadManager.pendingImportError = String(
				format: .localized("The shared file could not be read: %@"),
				error.localizedDescription
			)
			DownloadManager.shared.presentPendingImportErrorIfPossible()
			return nil
		}
	}
}

private struct PendingBackup: Identifiable {
	let id = UUID()
	let url: URL
}

class AppDelegate: NSObject, UIApplicationDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		LegacyMigration.runIfNeeded()
		NotificationManager.shared.start()
		LegacyMigration.resetAlternateIcon()
		_createPipeline()
		_createDocumentsDirectories()
		ResetView.clearWorkCache()
		IncomingLog.startRun()
		// Logs whether the profile's App ID matches the bundle ID (share import needs it).
		_ = OwnSigningIdentity.current
		IncomingInboxScanner.recordRunStart()
		// Certificates: files to Application Support + passwords to the Keychain (once; retried until complete).
		SecureCertificateMigration.runIfNeeded()
		_addDefaultCertificates()
		return true
	}

	/// Installs `QuillSceneDelegate` next to SwiftUI's own scene handling, so URLs that arrive with
	/// the scene connection (cold launch via "Open in" / share sheet) are captured at the UIKit level
	/// and queued instead of depending only on SwiftUI's `onOpenURL` delivery.
	func application(
		_ application: UIApplication,
		configurationForConnecting connectingSceneSession: UISceneSession,
		options: UIScene.ConnectionOptions
	) -> UISceneConfiguration {
		IncomingLog.notice("Scene connecting: \(IncomingURLRouter.summary(of: options))")
		let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
		configuration.delegateClass = QuillSceneDelegate.self
		return configuration
	}

	/// Not called for scene-based apps (URLs go to the scene); logged and queued in case iOS does.
	func application(
		_ app: UIApplication,
		open url: URL,
		options: [UIApplication.OpenURLOptionsKey: Any] = [:]
	) -> Bool {
		let source = options[.sourceApplication] as? String
		IncomingLog.notice("AppDelegate open URL: source=\(source ?? "-")")
		IncomingURLRouter.shared.enqueue(
			url,
			origin: .appDelegateOpen,
			openInPlace: options[.openInPlace] as? Bool,
			sourceApplication: source
		)
		return true
	}
	
	private func _createPipeline() {
		DataLoader.sharedUrlCache.diskCapacity = 0
		
		let pipeline = ImagePipeline {
			let dataLoader: DataLoader = {
				let config = URLSessionConfiguration.default
				config.urlCache = nil
				return DataLoader(configuration: config)
			}()
			let dataCache = try? DataCache(name: "Quill.datacache") // disk cache
			let imageCache = Nuke.ImageCache() // memory cache
			dataCache?.sizeLimit = 500 * 1024 * 1024
			imageCache.costLimit = 100 * 1024 * 1024
			$0.dataCache = dataCache
			$0.imageCache = imageCache
			$0.dataLoader = dataLoader
			$0.dataCachePolicy = .automatic
			$0.isStoringPreviewsInMemoryCache = false
		}
		
		ImagePipeline.shared = pipeline
	}
	
	private func _createDocumentsDirectories() {
		let fileManager = FileManager.default

		let directories: [URL] = [
			fileManager.archives,
			fileManager.signed,
			fileManager.unsigned
		]
		
		for url in directories {
			try? fileManager.createDirectoryIfNeeded(at: url)
		}
	}
	
	private func _addDefaultCertificates() {
		guard
			UserDefaults.standard.bool(forKey: "Quill.didImportDefaultCertificates") == false,
			let signingAssetsURL = Bundle.main.url(forResource: "signing-assets", withExtension: nil)
		else {
			return
		}
		
		do {
			let folderContents = try FileManager.default.contentsOfDirectory(
				at: signingAssetsURL,
				includingPropertiesForKeys: nil,
				options: .skipsHiddenFiles
			)
			
			for folderURL in folderContents {
				guard folderURL.hasDirectoryPath else { continue }
				
				let certName = folderURL.lastPathComponent
				
				let p12Url = folderURL.appendingPathComponent("cert.p12")
				let provisionUrl = folderURL.appendingPathComponent("cert.mobileprovision")
				let passwordUrl = folderURL.appendingPathComponent("cert.txt")
				
				guard
					FileManager.default.fileExists(atPath: p12Url.path),
					FileManager.default.fileExists(atPath: provisionUrl.path),
					FileManager.default.fileExists(atPath: passwordUrl.path)
				else {
					Logger.misc.warning("Skipping \(certName): missing required files")
					continue
				}
				
				let password = try String(contentsOf: passwordUrl, encoding: .utf8)
				
				FR.handleCertificateFiles(
					p12URL: p12Url,
					provisionURL: provisionUrl,
					p12Password: password,
					certificateName: certName,
					isDefault: true
				) { _ in
					
				}
			}
			UserDefaults.standard.set(true, forKey: "Quill.didImportDefaultCertificates")
		} catch {
			Logger.misc.error("Failed to list signing-assets: \(error, privacy: .public)")
		}
	}

}
