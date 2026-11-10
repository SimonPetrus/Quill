//
//  IPAHandler.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import Foundation
import Zip
import SwiftUI
import NimbleExtensions

final class AppFileHandler: NSObject, @unchecked Sendable {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private let _uniqueWorkDir: URL
	var uniqueWorkDirPayload: URL?

	private var _ipa: URL
	/// True when `_ipa` is a private temp download that we own and may delete (no copy was made).
	private var _ownsSource = false
	private let _install: Bool
	private let _download: Download?
	private let _sourceProvenance: SourceAppProvenance?
	
	init(
		file ipa: URL,
		install: Bool = false,
		download: Download? = nil,
		sourceProvenance: SourceAppProvenance? = nil
	) {
		self._ipa = ipa
		self._install = install
		self._download = download
		self._sourceProvenance = sourceProvenance ?? download?.sourceProvenance
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("QuillImport_\(_uuid)", isDirectory: true)
		
		super.init()
	}
	
	/// Rough multiplier of IPA size needed on disk: the archive itself, the extracted
	/// payload (usually larger than the compressed IPA) and the final move.
	private static let _diskSpaceFactor = 2.5
	
	private func _checkDiskSpace() throws {
		let size = (try? _ipa.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
		guard size > 0 else { return }
		let required = Int64(Double(size) * AppFileHandler._diskSpaceFactor)
		let values = try? URL(fileURLWithPath: NSHomeDirectory())
			.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
		guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
		if available < required {
			throw ImportedFileHandlerError.insufficientSpace(required: required, available: available)
		}
	}
	
	func copy() async throws {
		// Downloads already live in our own temp folder; copying a multi-GB IPA again
		// would double the disk usage for no reason, so use it in place (file based, no memory load).
		let tempPath = _fileManager.temporaryDirectory.standardizedFileURL.path
		_ownsSource = _ipa.standardizedFileURL.path.hasPrefix(tempPath + "/QuillDownloads/")
		
		try _checkDiskSpace()
		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
		if _ownsSource { return }
		
		let destinationURL = _uniqueWorkDir.appendingPathComponent(_ipa.lastPathComponent)

		try _fileManager.removeFileIfNeeded(at: destinationURL)
		
		try _fileManager.copyItem(at: _ipa, to: destinationURL)
		_ipa = destinationURL
	}
	
	func extract() async throws {
		if _ipa.pathExtension == "ipa" {
			Zip.addCustomFileExtension("ipa")
		}
		if _ipa.pathExtension == "tipa" {
			Zip.addCustomFileExtension("tipa")
		}
		
		let download = self._download
		
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			DispatchQueue.global(qos: .utility).async {
				do {
					// Zip does not reject "../" entry names: check them before anything is written
					do {
						try ZipEntryValidator.validate(self._ipa)
					} catch ZipEntryValidator.Failure.unsafePath(let name) {
						continuation.resume(throwing: ImportedFileHandlerError.unsafeArchive(name))
						return
					}
					
					try Zip.unzipFile(
						self._ipa,
						destination: self._uniqueWorkDir,
						overwrite: true,
						password: nil,
						progress: { progress in
							if let download = download {
								DispatchQueue.main.async {
									download.unpackageProgress = progress
									
									#if !targetEnvironment(macCatalyst)
									if #available(iOS 26.0, *) {
										BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
									}
									#endif
								}
							}
						}
					)
					
					self.uniqueWorkDirPayload = self._uniqueWorkDir.appendingPathComponent("Payload")
					continuation.resume()
				} catch {
					continuation.resume(throwing: ImportedFileHandlerError.extractionFailed(error.localizedDescription))
				}
			}
		}
	}
	
	func move() async throws {
		guard let payloadURL = uniqueWorkDirPayload else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		
		let destinationURL = try await _directory()
		
		guard _fileManager.fileExists(atPath: payloadURL.path) else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		
		try _fileManager.moveItem(at: payloadURL, to: destinationURL)
		
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}
	
	func addToDatabase() async throws {
		let app = try await _directory()
		
		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			return
		}
		
		let bundle = Bundle(url: appUrl)
		
		Storage.shared.addImported(
			uuid: _uuid,
			source: _sourceProvenance?.sourceRepositoryURL,
			appName: bundle?.name,
			appIdentifier: bundle?.bundleIdentifier,
			appVersion: bundle?.version,
			appIcon: bundle?.iconFileName
		) { _ in }
		
		if let sourceProvenance = _sourceProvenance {
			Storage.shared.addSourceMetadata(
				for: _uuid,
				kind: .imported,
				provenance: sourceProvenance
			)
		}
	}
	
	private func _directory() async throws -> URL {
		// Documents/Feather/Unsigned/\(UUID)
		_fileManager.unsigned(_uuid)
	}
	
	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
		// Also drop the downloaded IPA we used in place, so a failed/finished import leaves no multi-GB leftovers.
		if _ownsSource {
			try? _fileManager.removeItem(at: _ipa)
			// Each download lives in its own QuillDownloads/<UUID>/ folder; remove it too.
			let parent = _ipa.deletingLastPathComponent()
			if parent.deletingLastPathComponent().lastPathComponent == "QuillDownloads" {
				try? _fileManager.removeItem(at: parent)
			}
		}
	}
}

enum ImportedFileHandlerError: Error, LocalizedError {
	case payloadNotFound
	case insufficientSpace(required: Int64, available: Int64)
	case extractionFailed(String)
	case unsafeArchive(String)
	
	var errorDescription: String? {
		switch self {
		case .payloadNotFound:
			return .localized("The IPA does not contain a valid Payload folder.")
		case .insufficientSpace(let required, let available):
			return String(
				format: .localized("Not enough free space: %@ required, %@ available."),
				required.formattedByteCount,
				available.formattedByteCount
			)
		case .extractionFailed(let reason):
			return String(format: .localized("Could not extract the IPA: %@"), reason)
		case .unsafeArchive(let path):
			return String(format: .localized("The IPA was not imported because it contains a file path that leads outside the app: %@"), path)
		}
	}
}
