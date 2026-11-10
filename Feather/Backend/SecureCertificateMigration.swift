//
//  SecureCertificateMigration.swift
//  Quill
//
//  Migration of certificates to secure storage:
//  - files: Documents/Certificates/<uuid>  ->  Application Support/Quill/Certificates/<uuid>
//  - password: Core Data `password` -> Keychain
//  Nothing is removed before the copy / Keychain value has been verified. Any failing step leaves
//  that certificate as it was and is retried on the next launch: there is no "done" flag, the cheap
//  check below runs on every launch (old folder present, or a certificate still holding a password
//  in Core Data, e.g. because a Keychain write failed when it was added).
//

import Foundation
import CoreData
import OSLog

enum SecureCertificateMigration {
	/// Orphaned folders (no certificate record) are moved here instead of staying visible in Files.
	private static var _orphanDir: URL { FileManager.default.secureCertificates.appendingPathComponent("_orphaned", isDirectory: true) }

	/// Runs on the main thread (certificate files are tiny). Safe to call repeatedly.
	static func runIfNeeded() {
		let storage = Storage.shared
		let context = storage.context
		let fm = FileManager.default

		// Recovery / in-memory store: the certificate list is not trustworthy, never touch files then.
		let stores = storage.container.persistentStoreCoordinator.persistentStores
		guard
			Storage.startupNotice == nil,
			!stores.isEmpty,
			!stores.contains(where: { $0.url?.path == "/dev/null" })
		else {
			Logger.misc.error("Certificate migration skipped: store is in recovery or in-memory mode")
			return
		}

		let request: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		let certs: [CertificatePair]
		do {
			certs = try context.fetch(request)
		} catch {
			Logger.misc.error("Certificate migration: fetch failed, will retry: \(error.localizedDescription)")
			return
		}

		let oldRoot = fm.certificates
		let hasOldFolder = fm.fileExists(atPath: oldRoot.path)
		let hasPasswords = certs.contains { $0.password != nil }
		guard hasOldFolder || hasPasswords else { return }

		var needsSave = false

		for cert in certs {
			guard let uuid = cert.uuid else { continue }

			// (a) files
			_ = _migrateFiles(uuid: uuid, fm: fm)

			// (b) password
			if let password = cert.password, !password.isEmpty {
				if KeychainHelper.set(password, for: uuid), KeychainHelper.get(uuid) == password {
					cert.password = nil
					needsSave = true
				} else {
					Logger.misc.error("Certificate migration: Keychain write/verify failed for \(uuid), keeping Core Data value")
				}
			} else if cert.password != nil {
				cert.password = nil // empty string: nothing to protect
				needsSave = true
			}
		}

		if needsSave {
			do {
				try context.save() // synchronous on purpose
			} catch {
				// The Keychain holds the password and is read first; the old Core Data value is still on disk.
				Logger.misc.error("Certificate migration: save failed, will retry: \(error.localizedDescription)")
				context.rollback()
			}
		}

		// Whatever is left in the old folder has no certificate record: move it out of Files, never delete it.
		if hasOldFolder {
			_moveOrphans(known: Set(certs.compactMap { $0.uuid }), fm: fm)
			if let rest = try? fm.contentsOfDirectory(atPath: oldRoot.path), rest.isEmpty {
				try? fm.removeItem(at: oldRoot)
			}
		}
	}

	// MARK: Files

	/// Copies the whole old directory (recursively) to the new one, verifies, then removes the old directory.
	/// If anything cannot be copied or verified, the old directory stays untouched.
	private static func _migrateFiles(uuid: String, fm: FileManager) -> Bool {
		let oldDir = fm.certificates(uuid)
		guard fm.fileExists(atPath: oldDir.path) else { return true } // nothing to move (already migrated or new)

		let newDir = fm.secureCertificates(uuid)
		do {
			try fm.createSecureCertificateDirectory(newDir)
			let items = try fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)
			for item in items {
				let target = newDir.appendingPathComponent(item.lastPathComponent)
				if fm.fileExists(atPath: target.path), !_same(item, target, fm) {
					try fm.removeItem(at: target) // leftover of an interrupted attempt
				}
				if !fm.fileExists(atPath: target.path) {
					try fm.copyItem(at: item, to: target)
				}
				guard _same(item, target, fm) else {
					Logger.misc.error("Certificate migration: copy verification failed for \(uuid)")
					return false
				}
				_protect(target, fm)
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

	/// Equal file content, or equal directory trees (names, nested content).
	private static func _same(_ a: URL, _ b: URL, _ fm: FileManager) -> Bool {
		var aDir: ObjCBool = false, bDir: ObjCBool = false
		guard
			fm.fileExists(atPath: a.path, isDirectory: &aDir),
			fm.fileExists(atPath: b.path, isDirectory: &bDir),
			aDir.boolValue == bDir.boolValue
		else { return false }

		if aDir.boolValue {
			guard
				let ac = try? fm.contentsOfDirectory(atPath: a.path),
				let bc = try? fm.contentsOfDirectory(atPath: b.path),
				Set(ac) == Set(bc)
			else { return false }
			return ac.allSatisfy { _same(a.appendingPathComponent($0), b.appendingPathComponent($0), fm) }
		}

		guard let da = try? Data(contentsOf: a), let db = try? Data(contentsOf: b) else { return false }
		return da == db
	}

	private static func _protect(_ url: URL, _ fm: FileManager) {
		fm.protectCertificateItem(at: url)
		if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
			for case let child as URL in enumerator { fm.protectCertificateItem(at: child) }
		}
	}

	// MARK: Orphans

	private static func _moveOrphans(known: Set<String>, fm: FileManager) {
		let oldRoot = fm.certificates
		guard let children = try? fm.contentsOfDirectory(atPath: oldRoot.path) else { return }
		for name in children where !known.contains(name) {
			do {
				try fm.createSecureCertificateDirectory(_orphanDir)
				var target = _orphanDir.appendingPathComponent(name)
				if fm.fileExists(atPath: target.path) {
					target = _orphanDir.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970))")
				}
				try fm.moveItem(at: oldRoot.appendingPathComponent(name), to: target)
				_protect(target, fm)
			} catch {
				Logger.misc.error("Certificate migration: could not move orphan folder: \(error.localizedDescription)")
			}
		}
	}
}
