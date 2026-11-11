//
//  IncomingPackageImporter.swift
//  Quill
//

import Foundation
import UIKit
import NimbleExtensions
import OSLog

/// Imports `.ipa` / `.tipa` files handed to the app by other apps
/// ("Open in" / "Copy to Quill" from the share sheet of Telegram, Safari, Files, ...).
///
/// The incoming file is first staged into the app's own temp area (`tmp/QuillDownloads/<UUID>/`),
/// so the import does not depend on the lifetime of the system's Inbox copy or on security-scoped
/// access, and `AppFileHandler` uses it in place (no second copy) and deletes it when done.
enum IncomingPackageImporter {
	private static let _supportedExtensions: Set<String> = ["ipa", "tipa"]

	static func canHandle(_ url: URL) -> Bool {
		url.isFileURL && _supportedExtensions.contains(url.pathExtension.lowercased())
	}

	/// Call on the main thread: registers a progress item shown in the download header.
	static func handle(_ url: URL) {
		let id = "QuillManualDownload_\(UUID().uuidString)"
		let download = DownloadManager.shared.startArchive(from: url, id: id)
		let kind = IncomingURLRouter.kind(of: url)
		IncomingLog.notice("Import started: kind=\(kind) stage=staging")

		DispatchQueue.global(qos: .userInitiated).async {
			let result = Result { try _stage(url) }

			DispatchQueue.main.async {
				switch result {
				case .success(let stagedURL):
					IncomingLog.notice("Import staged: stage=unpacking")
					try? DownloadManager.shared.handlePachageFile(url: stagedURL, dl: download) { error in
						if let error {
							IncomingLog.error("Import failed: stage=unpacking error=\(Self._describe(error))")
						} else {
							IncomingLog.notice("Import finished: added to Library")
						}
					}
				case .failure(let error):
					IncomingLog.error("Import failed: stage=staging kind=\(kind) error=\(Self._describe(error))")
					DownloadManager.shared.cancelDownload(download)
					UINotificationFeedbackGenerator().notificationOccurred(.error)
					DownloadManager.pendingImportError = ErrorExplainer.message(for: error)
					DownloadManager.shared.presentPendingImportErrorIfPossible()
				}
			}
		}
	}

	/// Error type, domain and code for the log; never includes file paths or names.
	private static func _describe(_ error: Error) -> String {
		switch error {
		case let error as IncomingPackageError:
			switch error {
			case .notAPackage: return "notAPackage"
			case .unreadable: return "unreadable"
			}
		case let error as ImportedFileHandlerError:
			switch error {
			case .payloadNotFound: return "payloadNotFound"
			case .insufficientSpace: return "insufficientSpace"
			case .extractionFailed: return "extractionFailed"
			case .unsafeArchive: return "unsafeArchive"
			}
		default:
			let nsError = error as NSError
			return "\(nsError.domain)#\(nsError.code)"
		}
	}

	// MARK: - Staging

	private static func _stage(_ source: URL) throws -> URL {
		let fileManager = FileManager.default
		// Open-in-place / File Provider URLs need security-scoped access; Inbox copies do not
		// (the call then returns false, which is fine — the file is still readable).
		let isScoped = source.startAccessingSecurityScopedResource()
		let isInbox = IncomingURLRouter.isOwnInboxCopy(source)
		IncomingLog.notice("Staging: scoped=\(isScoped) inbox=\(isInbox)")
		defer {
			if isScoped { source.stopAccessingSecurityScopedResource() }
		}

		let stagingDirectory = fileManager.temporaryDirectory
			.appendingPathComponent("QuillDownloads", isDirectory: true)
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fileManager.createDirectoryIfNeeded(at: stagingDirectory)

		// The unzip step only accepts lower-case `ipa` / `tipa`, so normalize "App.IPA".
		let baseName = source.deletingPathExtension().lastPathComponent
		let fileName = (baseName.isEmpty ? "app" : baseName) + "." + source.pathExtension.lowercased()
		let destination = stagingDirectory.appendingPathComponent(fileName)

		do {
			try _checkFreeSpace(for: source, inPlaceMove: isInbox)
			if isInbox {
				// The system's Inbox copy belongs to us: moving is instant, needs no extra
				// space and leaves nothing behind in the Inbox.
				do {
					try fileManager.moveItem(at: source, to: destination)
				} catch {
					try fileManager.copyItem(at: source, to: destination)
					try? fileManager.removeItem(at: source)
				}
			} else {
				try _coordinatedCopy(from: source, to: destination)
			}

			guard _hasZipSignature(destination) else {
				throw IncomingPackageError.notAPackage(source.lastPathComponent)
			}
			return destination
		} catch {
			try? fileManager.removeItem(at: stagingDirectory)
			// A failed Inbox copy must not be found again by the Inbox scan on every launch;
			// the original stays in the sharing app, so the user can simply share it again.
			if isInbox { try? fileManager.removeItem(at: source) }
			let nsError = error as NSError
			IncomingLog.error("Staging error: scoped=\(isScoped) inbox=\(isInbox) domain=\(nsError.domain) code=\(nsError.code)")
			if let error = error as? IncomingPackageError { throw error }
			if let error = error as? ImportedFileHandlerError { throw error }
			throw IncomingPackageError.unreadable(error.localizedDescription)
		}
	}

	/// A copy needs about the file's size again (a move needs nothing); fail early with a clear message.
	private static func _checkFreeSpace(for source: URL, inPlaceMove: Bool) throws {
		guard !inPlaceMove else { return }
		let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
		guard size > 0 else { return }
		let values = try? URL(fileURLWithPath: NSHomeDirectory())
			.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
		guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
		if available < size {
			throw ImportedFileHandlerError.insufficientSpace(required: size, available: available)
		}
	}

	/// Copies through `NSFileCoordinator`, which also downloads iCloud / File Provider items first.
	private static func _coordinatedCopy(from source: URL, to destination: URL) throws {
		var coordinatorError: NSError?
		var copyError: Error?

		NSFileCoordinator().coordinate(
			readingItemAt: source,
			options: [.withoutChanges],
			error: &coordinatorError
		) { readURL in
			do {
				try FileManager.default.copyItem(at: readURL, to: destination)
			} catch {
				copyError = error
			}
		}

		if let error = copyError ?? coordinatorError {
			throw error
		}
	}

	/// IPA files are ZIP archives: they start with a local file header ("PK\u{3}\u{4}").
	private static func _hasZipSignature(_ url: URL) -> Bool {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
		defer { try? handle.close() }
		guard let header = try? handle.read(upToCount: 4) else { return false }
		return header == Data([0x50, 0x4B, 0x03, 0x04])
	}
}

enum IncomingPackageError: Error, LocalizedError {
	case notAPackage(String)
	case unreadable(String)

	var errorDescription: String? {
		switch self {
		case .notAPackage(let name):
			return String(format: .localized("“%@” is not a valid IPA file."), name)
		case .unreadable(let reason):
			return String(format: .localized("The shared file could not be read: %@"), reason)
		}
	}
}
