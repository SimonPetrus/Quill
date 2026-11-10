//
//  SecureCertificateMigration.swift
//  Quill
//
//  One-time migration of existing certificates to secure storage:
//  - files: Documents/Certificates/<uuid>  ->  Application Support/Quill/Certificates/<uuid>
//  - password: Core Data `password` -> Keychain
//  Nothing is removed before the copy / Keychain value has been verified. Any failing step leaves
//  that certificate as it was, and the flag is not written, so the next launch retries.
//

import Foundation
import CoreData
import OSLog

enum SecureCertificateMigration {
	static let doneKey = "Quill.didMigrateSecureCertificates"

	/// Runs on the main thread (certificate files are tiny). Safe to call repeatedly.
	static func runIfNeeded() {
		let defaults = UserDefaults.standard
		guard !defaults.bool(forKey: doneKey) else { return }

		let storage = Storage.shared
		let context = storage.context
		let fm = FileManager.default
		var allOK = true
		var needsSave = false

		let request: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		let certs: [CertificatePair]
		do {
			certs = try context.fetch(request)
		} catch {
			Logger.misc.error("Certificate migration: fetch failed, will retry: \(error.localizedDescription)")
			return
		}

		for cert in certs {
			guard let uuid = cert.uuid else { continue }

			// (a) files
			if !_migrateFiles(uuid: uuid, fm: fm) { allOK = false }

			// (b) password
			if let password = cert.password, !password.isEmpty {
				if KeychainHelper.set(password, for: uuid), KeychainHelper.get(uuid) == password {
					cert.password = nil
					needsSave = true
				} else {
					Logger.misc.error("Certificate migration: Keychain write/verify failed for \(uuid), keeping Core Data value")
					allOK = false
				}
			} else if cert.password != nil {
				cert.password = nil // empty string: nothing to protect
				needsSave = true
			}
		}

		if needsSave {
			do {
				try context.save() // synchronous on purpose: the flag must not be set before this succeeded
			} catch {
				// The Keychain holds the password and is read first; the old Core Data value is still on disk.
				Logger.misc.error("Certificate migration: save failed, will retry: \(error.localizedDescription)")
				context.rollback()
				allOK = false
			}
		}

		guard allOK else {
			Logger.misc.error("Certificate migration incomplete, will retry on next launch")
			return
		}

		// Old Documents/Certificates folder is removed only when it is empty (orphans stay untouched).
		let old = fm.certificates
		if let rest = try? fm.contentsOfDirectory(atPath: old.path), rest.isEmpty {
			try? fm.removeItem(at: old)
		}
		defaults.set(true, forKey: doneKey)
	}

	/// Copies every file of the old directory to the new one, verifies, then removes the old directory.
	private static func _migrateFiles(uuid: String, fm: FileManager) -> Bool {
		let oldDir = fm.certificates(uuid)
		guard fm.fileExists(atPath: oldDir.path) else { return true } // nothing to move (already migrated or new)

		let newDir = fm.secureCertificates(uuid)
		func size(_ url: URL) -> Int? {
			(try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int
		}

		do {
			try fm.createSecureCertificateDirectory(newDir)
			let items = try fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)
			for item in items {
				var isDir: ObjCBool = false
				guard fm.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue else { continue }
				let target = newDir.appendingPathComponent(item.lastPathComponent)
				let sourceSize = size(item)
				if fm.fileExists(atPath: target.path), size(target) != sourceSize {
					try fm.removeItem(at: target) // leftover of an interrupted attempt
				}
				if !fm.fileExists(atPath: target.path) {
					try fm.copyItem(at: item, to: target)
				}
				guard let sourceSize, size(target) == sourceSize, Self._sameContent(item, target) else {
					Logger.misc.error("Certificate migration: copy verification failed for \(uuid)")
					return false
				}
				fm.protectCertificateItem(at: target)
			}
			fm.protectCertificateItem(at: newDir)
			// Everything verified: only now the old directory goes.
			try fm.removeItem(at: oldDir)
			return true
		} catch {
			Logger.misc.error("Certificate migration: files failed for \(uuid), keeping old location: \(error.localizedDescription)")
			return false
		}
	}

	private static func _sameContent(_ a: URL, _ b: URL) -> Bool {
		guard let da = try? Data(contentsOf: a), let db = try? Data(contentsOf: b) else { return false }
		return da == db
	}
}
