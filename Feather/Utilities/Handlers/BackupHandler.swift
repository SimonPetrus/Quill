//
//  BackupHandler.swift
//  Quill
//
//  Backup / restore of settings, sources and (optionally) certificates.
//
//  File format (`.quillbackup`):
//   - Without certificates: a plain zip.
//   - With certificates (always encrypted): header + AES-GCM sealed zip
//       "QLBK" (4) | version (1) | PBKDF2 iterations, UInt32 BE (4) | salt (16) | nonce (12) | ciphertext | tag (16)
//     key = PBKDF2-HMAC-SHA256(password, salt, iterations) -> 32 bytes; the header is the GCM AAD.
//   The zip is flat: manifest.json, options.json, defaults.json, sources.json, certificates.json,
//   cert-<uuid>.p12, cert-<uuid>.mobileprovision.
//  The password is never stored or logged.
//

import Foundation
import CryptoKit
import CommonCrypto
import CoreData
import UniformTypeIdentifiers
import OSLog
import Zip

extension UTType {
	static let quillBackup = UTType(exportedAs: "app.quill.sign.backup", conformingTo: .data)
}

// MARK: - Errors
enum BackupError: LocalizedError {
	case passwordTooShort
	case passwordRequired
	case wrongPassword
	case invalidFile
	case corruptArchive
	case unsupportedVersion
	case failed(String)

	var errorDescription: String? {
		switch self {
		case .passwordTooShort: return .localized("The password must be at least 8 characters.")
		case .passwordRequired: return .localized("This backup is encrypted. Enter its password.")
		case .wrongPassword: return .localized("Wrong password, or the backup file is damaged.")
		case .invalidFile: return .localized("This file is not a valid Quill backup.")
		case .corruptArchive: return .localized("The backup file is corrupt or not safe.")
		case .unsupportedVersion: return .localized("This backup was made by a newer version of Quill.")
		case .failed(let message): return message
		}
	}
}

// MARK: - Crypto
enum BackupCrypto {
	static let magic = Data("QLBK".utf8)
	static let version: UInt8 = 1
	static let iterations: UInt32 = 600_000
	private static let _saltLength = 16
	private static let _tagLength = 16
	private static let _headerLength = 4 + 1 + 4 + 16 + 12
	private static let _minIterations: UInt32 = 100_000
	private static let _maxIterations: UInt32 = 10_000_000

	static func isEncrypted(_ data: Data) -> Bool {
		data.count >= magic.count && data.prefix(magic.count) == magic
	}

	static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
		var derived = [UInt8](repeating: 0, count: 32)
		let passwordLength = password.utf8.count
		let status = password.withCString { pw in
			salt.withUnsafeBytes { (saltBytes: UnsafeRawBufferPointer) in
				derived.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
					CCKeyDerivationPBKDF(
						CCPBKDFAlgorithm(kCCPBKDF2),
						pw,
						passwordLength,
						saltBytes.bindMemory(to: UInt8.self).baseAddress,
						salt.count,
						CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
						iterations,
						out.bindMemory(to: UInt8.self).baseAddress,
						32
					)
				}
			}
		}
		guard status == kCCSuccess else { throw BackupError.failed(.localized("Encryption failed.")) }
		return SymmetricKey(data: Data(derived))
	}

	static func encrypt(_ plain: Data, password: String) throws -> Data {
		var salt = Data(count: _saltLength)
		let rc = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, _saltLength, $0.baseAddress!) }
		guard rc == errSecSuccess else { throw BackupError.failed(.localized("Encryption failed.")) }
		let nonce = AES.GCM.Nonce()

		var header = magic
		header.append(version)
		var iterBE = iterations.bigEndian
		header.append(Data(bytes: &iterBE, count: 4))
		header.append(salt)
		header.append(Data(nonce))

		let key = try deriveKey(password: password, salt: salt, iterations: iterations)
		let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: header)
		return header + sealed.ciphertext + sealed.tag
	}

	static func decrypt(_ input: Data, password: String) throws -> Data {
		let blob = Data(input) // zero-based indices
		guard blob.count > _headerLength + _tagLength, isEncrypted(blob) else {
			throw BackupError.invalidFile
		}
		guard blob[4] == version else {
			throw blob[4] > version ? BackupError.unsupportedVersion : BackupError.invalidFile
		}
		let iter = blob[5..<9].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
		guard iter >= _minIterations, iter <= _maxIterations else { throw BackupError.invalidFile }
		let salt = Data(blob[9..<25])
		let nonceData = Data(blob[25..<37])
		let header = Data(blob[0..<_headerLength])
		let ciphertext = Data(blob[_headerLength..<(blob.count - _tagLength)])
		let tag = Data(blob[(blob.count - _tagLength)...])

		let key = try deriveKey(password: password, salt: salt, iterations: iter)
		do {
			let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)
			return try AES.GCM.open(box, using: key, authenticating: header)
		} catch {
			throw BackupError.wrongPassword
		}
	}
}

// MARK: - Models
private struct BackupManifest: Codable {
	var format: Int
	var app: String
	var appVersion: String
	var created: Date
	var includesSettings: Bool
	var sourceCount: Int
	var certificateCount: Int
	var encrypted: Bool
}

private struct BackupSource: Codable {
	var identifier: String
	var name: String?
	var url: String
	var iconURL: String?
	var pinned: Bool
}

private struct BackupCertificate: Codable {
	var uuid: String
	var nickname: String?
	var expiration: Date
	var ppq: Bool
	var password: String
	var p12: String
	var provision: String
}

struct BackupSummary {
	var settingsRestored = false
	var sourcesAdded = 0
	var sourcesSkipped = 0
	var certificatesAdded = 0
	var certificatesSkipped = 0
	var certificatesFailed = 0
	/// The backup was not encrypted but contained certificates: they were ignored.
	var certificatesIgnored = false
}

// MARK: - Handler
enum BackupHandler {
	static let formatVersion = 1
	static let minPasswordLength = 8
	private static let _optionsKey = OptionsManager.storageKey
	/// Non-sensitive preferences only.
	private static let _defaultsKeys = [
		"Quill.userInterfaceStyle", "Quill.userTintColor", "Quill.installationMethod",
		"Quill.compressionLevel", "Quill.useShareSheetForArchiving", "Quill.storeCellAppearance",
		"Quill.shouldTintIcons", "Quill.shouldChangeIconsBasedOffStyle", "Quill.sortOptionRawValue",
		"Quill.sortAscending", "Quill.ipFix", "Quill.serverMethod"
	]
	/// Options that point to files inside this device's app container: meaningless elsewhere.
	private static let _localOptionKeys = ["appEntitlementsFile", "injectionFiles"]

	private static func _workDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuillBackup-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	private static func _makeEncoder() -> JSONEncoder {
		let e = JSONEncoder()
		e.dateEncodingStrategy = .iso8601
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		return e
	}

	private static func _makeDecoder() -> JSONDecoder {
		let d = JSONDecoder()
		d.dateDecodingStrategy = .iso8601
		return d
	}

	// MARK: Create

	/// Builds the backup file and returns its URL (in a temporary folder, ready for the share sheet).
	/// Reads Core Data on the main actor; the heavy part (zip, key derivation) runs off-main.
	@MainActor
	static func createBackup(includeCertificates: Bool, password: String?) async throws -> (url: URL, skippedCertificates: Int) {
		if includeCertificates {
			guard let password, password.count >= minPasswordLength else { throw BackupError.passwordTooShort }
		}

		// Gather on main
		var defaultsOut: [String: Any] = [:]
		for key in _defaultsKeys {
			if let value = UserDefaults.standard.object(forKey: key), value is String || value is NSNumber {
				defaultsOut[key] = value
			}
		}
		var optionsDict: [String: Any] = [:]
		if
			let data = UserDefaults.standard.data(forKey: _optionsKey),
			let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		{
			optionsDict = dict
			for key in _localOptionKeys { optionsDict.removeValue(forKey: key) }
		}

		let sources: [BackupSource] = Storage.shared.getSources().compactMap { source in
			guard let url = source.sourceURL else { return nil }
			return BackupSource(
				identifier: source.identifier ?? url.absoluteString,
				name: source.name,
				url: url.absoluteString,
				iconURL: source.iconURL?.absoluteString,
				pinned: source.isPinned
			)
		}

		var skippedCertificates = 0
		var certEntries: [BackupCertificate] = []
		var certFiles: [(name: String, url: URL)] = []
		if includeCertificates {
			for cert in Storage.shared.getAllCertificates() {
				// Bundled default certificates come with the app itself.
				guard let uuid = cert.uuid, cert.isDefault != true else { continue }
				guard
					let p12 = Storage.shared.getFile(.certificate, from: cert),
					let provision = Storage.shared.getFile(.provision, from: cert)
				else {
					skippedCertificates += 1
					continue
				}
				let p12Name = "cert-\(uuid).p12"
				let provisionName = "cert-\(uuid).mobileprovision"
				certFiles.append((p12Name, p12))
				certFiles.append((provisionName, provision))
				certEntries.append(BackupCertificate(
					uuid: uuid,
					nickname: cert.nickname,
					expiration: cert.expiration ?? Date(),
					ppq: cert.ppQCheck,
					password: cert.resolvedPassword,
					p12: p12Name,
					provision: provisionName
				))
			}
		}

		let manifest = BackupManifest(
			format: formatVersion,
			app: "Quill",
			appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
			created: Date(),
			includesSettings: true,
			sourceCount: sources.count,
			certificateCount: certEntries.count,
			encrypted: includeCertificates
		)

		let defaultsFinal = defaultsOut
		let optionsFinal = optionsDict
		let certEntriesFinal = certEntries
		let certFilesFinal = certFiles
		let passwordFinal = password
		let skipped = skippedCertificates
		let url = try await Task.detached(priority: .userInitiated) { () -> URL in
			let work = try _workDirectory()
			defer { try? FileManager.default.removeItem(at: work) }

			var paths: [URL] = []
			func write(_ name: String, _ data: Data) throws {
				let url = work.appendingPathComponent(name)
				try data.write(to: url, options: .atomic)
				paths.append(url)
			}
			try write("manifest.json", try _makeEncoder().encode(manifest))
			try write("options.json", try JSONSerialization.data(withJSONObject: optionsFinal, options: [.sortedKeys]))
			try write("defaults.json", try JSONSerialization.data(withJSONObject: defaultsFinal, options: [.sortedKeys]))
			try write("sources.json", try _makeEncoder().encode(sources))
			if !certEntriesFinal.isEmpty {
				try write("certificates.json", try _makeEncoder().encode(certEntriesFinal))
				for file in certFilesFinal {
					let target = work.appendingPathComponent(file.name)
					try FileManager.default.copyItem(at: file.url, to: target)
					paths.append(target)
				}
			}

			// The zip library only accepts a zip-like extension.
			let zipURL = work.appendingPathComponent("backup.zip")
			try Zip.zipFiles(paths: paths, zipFilePath: zipURL, password: nil, progress: nil)
			var output = try Data(contentsOf: zipURL)
			if includeCertificates, let passwordFinal {
				output = try BackupCrypto.encrypt(output, password: passwordFinal)
			}

			let stamp = DateFormatter()
			stamp.dateFormat = "yyyy-MM-dd"
			stamp.locale = Locale(identifier: "en_US_POSIX")
			let shareDir = FileManager.default.temporaryDirectory.appendingPathComponent("QuillBackupShare-\(UUID().uuidString)", isDirectory: true)
			try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
			let final = shareDir.appendingPathComponent("Quill-Backup-\(stamp.string(from: Date())).quillbackup")
			try output.write(to: final, options: [.atomic, .completeFileProtection])
			return final
		}.value
		return (url, skipped)
	}

	// MARK: Restore

	/// True if the file needs a password. Reads only the first bytes.
	static func isEncrypted(at url: URL) throws -> Bool {
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		let head = try handle.read(upToCount: 4) ?? Data()
		if head == BackupCrypto.magic { return true }
		if head.starts(with: Data("PK".utf8)) { return false }
		throw BackupError.invalidFile
	}

	/// Restores everything in the backup that does not exist yet. Existing certificates (same uuid) and
	/// sources (same identifier or URL) are skipped, never overwritten.
	static func restore(from url: URL, password: String?) async throws -> BackupSummary {
		let work = try _workDirectory()
		defer { try? FileManager.default.removeItem(at: work) }

		// Decrypt / unzip off-main
		let (extracted, wasEncrypted) = try await Task.detached(priority: .userInitiated) { () -> (URL, Bool) in
			let raw = try Data(contentsOf: url)
			var zipData = raw
			let encrypted = BackupCrypto.isEncrypted(raw)
			if encrypted {
				guard let password, !password.isEmpty else { throw BackupError.passwordRequired }
				zipData = try BackupCrypto.decrypt(raw, password: password)
			} else if !raw.starts(with: Data("PK".utf8)) {
				throw BackupError.invalidFile
			}
			let zipURL = work.appendingPathComponent("restore.zip")
			try zipData.write(to: zipURL, options: .atomic)
			let dest = work.appendingPathComponent("x", isDirectory: true)
			try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
			do {
				// Zip does not reject "../" entry names (zip slip): check them before extracting
				try ZipEntryValidator.validate(zipURL)
				try Zip.unzipFile(zipURL, destination: dest, overwrite: true, password: nil)
			} catch {
				throw BackupError.corruptArchive
			}
			return (dest, encrypted)
		}.value

		return try await MainActor.run { try _apply(from: extracted, encrypted: wasEncrypted) }
	}

	@MainActor
	private static func _apply(from dir: URL, encrypted: Bool) throws -> BackupSummary {
		let fm = FileManager.default
		let decoder = _makeDecoder()
		guard
			let manifestData = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
			let manifest = try? decoder.decode(BackupManifest.self, from: manifestData),
			manifest.app == "Quill"
		else { throw BackupError.invalidFile }
		guard manifest.format <= formatVersion else { throw BackupError.unsupportedVersion }

		var summary = BackupSummary()

		// Settings
		var settingsOK = false
		if
			let data = try? Data(contentsOf: dir.appendingPathComponent("defaults.json")),
			let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		{
			for (key, value) in dict where _defaultsKeys.contains(key) && (value is String || value is NSNumber) {
				UserDefaults.standard.set(value, forKey: key)
			}
			settingsOK = true
		}
		if
			let data = try? Data(contentsOf: dir.appendingPathComponent("options.json")),
			var saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			!saved.isEmpty
		{
			for key in _localOptionKeys { saved.removeValue(forKey: key) }
			if
				let current = try? JSONEncoder().encode(OptionsManager.shared.options),
				var merged = try? JSONSerialization.jsonObject(with: current) as? [String: Any]
			{
				for (key, value) in saved { merged[key] = value }
				if
					let mergedData = try? JSONSerialization.data(withJSONObject: merged),
					let options = try? JSONDecoder().decode(Options.self, from: mergedData)
				{
					OptionsManager.shared.options = options
					settingsOK = true
				}
			}
		}
		summary.settingsRestored = settingsOK

		// Sources
		if
			let data = try? Data(contentsOf: dir.appendingPathComponent("sources.json")),
			let sources = try? decoder.decode([BackupSource].self, from: data)
		{
			let existing = Storage.shared.getSources()
			var knownIDs = Set(existing.compactMap { $0.identifier })
			var knownURLs = Set(existing.compactMap { $0.sourceURL?.absoluteString })
			for item in sources {
				guard let url = URL(string: item.url), url.scheme != nil else {
					summary.sourcesSkipped += 1
					continue
				}
				if knownIDs.contains(item.identifier) || knownURLs.contains(item.url) {
					summary.sourcesSkipped += 1
					continue
				}
				Storage.shared.addSource(
					url,
					name: item.name,
					identifier: item.identifier,
					iconURL: item.iconURL.flatMap { URL(string: $0) },
					deferSave: true
				) { _ in }
				if item.pinned, let added = Storage.shared.getSources().first(where: { $0.identifier == item.identifier }) {
					added.isPinned = true
				}
				knownIDs.insert(item.identifier)
				knownURLs.insert(item.url)
				summary.sourcesAdded += 1
			}
			try? Storage.shared.context.save()
		}

		// Certificates (same path as a normal import: secure folder + Keychain).
		// Only from the encrypted container: a plain zip never carries certificates written by Quill.
		let certificatesURL = dir.appendingPathComponent("certificates.json")
		if !encrypted && fm.fileExists(atPath: certificatesURL.path) {
			summary.certificatesIgnored = true
		}
		if
			encrypted,
			let data = try? Data(contentsOf: certificatesURL),
			let certs = try? decoder.decode([BackupCertificate].self, from: data)
		{
			var knownUUIDs = Set(Storage.shared.getAllCertificates().compactMap { $0.uuid?.uppercased() })
			for item in certs {
				guard UUID(uuidString: item.uuid) != nil else {
					summary.certificatesFailed += 1
					continue
				}
				let uuid = item.uuid
				let secureDir = fm.secureCertificates(uuid)
				if
					knownUUIDs.contains(uuid.uppercased())
					|| fm.fileExists(atPath: secureDir.path)
					|| fm.fileExists(atPath: fm.certificates(uuid).path)
				{
					summary.certificatesSkipped += 1
					continue
				}
				// Only the exact names written by the backup are read (no path components).
				guard
					item.p12 == "cert-\(uuid).p12",
					item.provision == "cert-\(uuid).mobileprovision",
					// plain file names only, never a path out of the restore folder
					(try? ArchivePathValidator.fileName(item.p12)) == item.p12,
					(try? ArchivePathValidator.fileName(item.provision)) == item.provision,
					fm.fileExists(atPath: dir.appendingPathComponent(item.p12).path),
					fm.fileExists(atPath: dir.appendingPathComponent(item.provision).path)
				else {
					summary.certificatesFailed += 1
					continue
				}

				do {
					try fm.createSecureCertificateDirectory(secureDir)
					for (name, target) in [(item.p12, "\(uuid).p12"), (item.provision, "\(uuid).mobileprovision")] {
						let source = dir.appendingPathComponent(name)
						let dest = secureDir.appendingPathComponent(target)
						try fm.copyItem(at: source, to: dest)
						let original = try Data(contentsOf: source)
						let copied = try Data(contentsOf: dest)
						guard original == copied else { throw BackupError.invalidFile }
						fm.protectCertificateItem(at: dest)
					}
				} catch {
					Logger.misc.error("Backup restore: certificate files could not be written: \(error.localizedDescription)")
					try? fm.removeItem(at: secureDir)
					summary.certificatesFailed += 1
					continue
				}
				Storage.shared.addCertificate(
					uuid: uuid,
					password: item.password,
					nickname: item.nickname,
					ppq: item.ppq,
					expiration: item.expiration,
					isDefault: false
				) { _ in }
				knownUUIDs.insert(uuid.uppercased())
				summary.certificatesAdded += 1
			}
		}

		return summary
	}
}
