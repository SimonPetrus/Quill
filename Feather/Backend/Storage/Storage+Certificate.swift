//
//  Storage+Certificate.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator
import Zsign

// MARK: - Class extension: certificate
extension Storage {
	func addCertificate(
		uuid: String,
		password: String? = nil,
		nickname: String? = nil,
		ppq: Bool = false,
		expiration: Date,
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		let generator = UIImpactFeedbackGenerator(style: .light)
		
		let new = CertificatePair(context: context)
		new.uuid = uuid
		new.date = Date()
		// The password goes to the Keychain; Core Data keeps it only if the Keychain write fails
		// (never lose the password).
		if let password, !password.isEmpty {
			new.password = KeychainHelper.set(password, for: uuid) ? nil : password
		} else {
			new.password = nil
		}
		new.ppQCheck = ppq
		new.expiration = expiration
		new.nickname = nickname
		new.isDefault = isDefault
		CertificatePasswordCache.shared.invalidate(uuid)
		Storage.shared.revokagedCertificate(for: new)
		saveContext()
		generator.impactOccurred()
		completion(nil)
	}
	
	func deleteCertificate(for cert: CertificatePair) {
		if let uuid = cert.uuid {
			for url in FileManager.default.certificateDirectories(uuid) {
				try? FileManager.default.removeItem(at: url)
			}
			KeychainHelper.delete(uuid)
			CertificatePasswordCache.shared.invalidate(uuid)
		}
		context.delete(cert)
		saveContext()
	}
	
	func getCertificate(for index: Int) -> CertificatePair? {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]

		guard
			let results = try? context.fetch(fetchRequest),
			index >= 0 && index < results.count
		else {
			return nil
		}
		
		return results[index]
	}
	
	func revokagedCertificate(for cert: CertificatePair) {
		guard !cert.revoked else { return }
		
		Zsign.checkRevokage(
			provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
			p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
			p12Password: cert.resolvedPassword
		) { (status, _, _) in
			if status == 1 {
				DispatchQueue.main.async {
					cert.revoked = true
					self.saveContext()
				}
			}
		}
	}
	
	enum FileRequest: String {
		case certificate = "p12"
		case provision = "mobileprovision"
	}
	
	func getFile(_ type: FileRequest, from cert: CertificatePair) -> URL? {
		guard let uuid = cert.uuid else {
			return nil
		}
		
		// New location first, then the legacy one (also covers a half-finished migration).
		for url in FileManager.default.certificateDirectories(uuid) {
			if let file = FileManager.default.getPath(in: url, for: type.rawValue) {
				return file
			}
		}
		return nil
	}
	
	func getProvisionFileDecoded(for cert: CertificatePair) -> Certificate? {
		guard let url = getFile(.provision, from: cert) else {
			return nil
		}
		
		let read = CertificateReader(url)
		return read.decoded
	}
	
	func getAllCertificates() -> [CertificatePair] {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
		return (try? context.fetch(fetchRequest)) ?? []
	}
}

// MARK: - Password
extension CertificatePair {
	/// The only place that reads a certificate password: Keychain first, then the legacy Core Data value
	/// (certificates not migrated yet, or Keychain write failed). Empty string when there is none.
	var resolvedPassword: String {
		if let uuid, let stored = KeychainHelper.get(uuid) {
			return stored
		}
		return password ?? ""
	}
}

// MARK: - Missing password (e.g. device restored from a backup: Keychain items do not move between devices)
enum PasswordCheck {
	case ok
	case wrong
	/// Files missing / could not be copied: nothing can be said about the password.
	case unverifiable
}

enum PasswordUpdateResult {
	case ok, wrong, unverifiable, keychainFailed
}

extension Notification.Name {
	/// Posted on the main thread when a certificate password state may have changed.
	static let certificatePasswordStateChanged = Notification.Name("Quill.certificatePasswordStateChanged")
}

/// In-memory cache: uuid -> "password is missing". The p12 check is not free, so it runs once per uuid.
final class CertificatePasswordCache {
	static let shared = CertificatePasswordCache()
	private let _lock = NSLock()
	private var _missing: [String: Bool] = [:]

	func value(for uuid: String) -> Bool? {
		_lock.lock(); defer { _lock.unlock() }
		return _missing[uuid]
	}

	func set(_ value: Bool, for uuid: String) {
		_lock.lock(); defer { _lock.unlock() }
		_missing[uuid] = value
	}

	/// Drops the cached state (all when `uuid` is nil) and tells the UI to refresh.
	func invalidate(_ uuid: String? = nil) {
		_lock.lock()
		if let uuid { _missing.removeValue(forKey: uuid) } else { _missing.removeAll() }
		_lock.unlock()
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: .certificatePasswordStateChanged, object: nil)
		}
	}
}

extension CertificatePair {
	/// True when no password is stored anywhere for this certificate AND its p12 actually needs one.
	/// Cached per uuid; "unverifiable" counts as not missing.
	var isPasswordMissing: Bool {
		guard let uuid, resolvedPassword.isEmpty else { return false }
		if let cached = CertificatePasswordCache.shared.value(for: uuid) { return cached }
		let missing = Storage.checkPassword("", for: self) == .wrong
		CertificatePasswordCache.shared.set(missing, for: uuid)
		return missing
	}

	/// Same as `isPasswordMissing`, but the p12 check runs in the background.
	func loadPasswordMissing(_ completion: @escaping (Bool) -> Void) {
		guard let uuid, resolvedPassword.isEmpty else { return completion(false) }
		if let cached = CertificatePasswordCache.shared.value(for: uuid) { return completion(cached) }
		let p12 = Storage.shared.getFile(.certificate, from: self)
		let provision = Storage.shared.getFile(.provision, from: self)
		Task.detached(priority: .utility) {
			let missing = Storage.checkPassword("", p12: p12, provision: provision) == .wrong
			CertificatePasswordCache.shared.set(missing, for: uuid)
			await MainActor.run { completion(missing) }
		}
	}

	/// Verifies `newPassword` against the p12 and writes it to the Keychain (never Core Data) only if it is
	/// verified correct. A password that cannot be verified is never written.
	func updatePassword(_ newPassword: String) -> PasswordUpdateResult {
		guard let uuid else { return .unverifiable }
		switch Storage.checkPassword(newPassword, for: self) {
		case .wrong: return .wrong
		case .unverifiable: return .unverifiable
		case .ok: break
		}
		if newPassword.isEmpty {
			KeychainHelper.delete(uuid)
		} else if !KeychainHelper.set(newPassword, for: uuid) {
			return .keychainFailed
		}
		if password != nil {
			password = nil
			Storage.shared.saveContext()
		}
		CertificatePasswordCache.shared.invalidate(uuid)
		return .ok
	}
}

extension Storage {
	static func checkPassword(_ password: String, for cert: CertificatePair) -> PasswordCheck {
		checkPassword(
			password,
			p12: Storage.shared.getFile(.certificate, from: cert),
			provision: Storage.shared.getFile(.provision, from: cert)
		)
	}

	/// Checks a password against temporary, protected copies of the files (the check helper patches the profile).
	/// Thread-safe: touches no Core Data objects.
	static func checkPassword(_ password: String, p12: URL?, provision: URL?) -> PasswordCheck {
		guard let p12, let provision else { return .unverifiable }
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appendingPathComponent("QuillPwCheck-\(UUID().uuidString)", isDirectory: true)
		defer { try? fm.removeItem(at: dir) }
		do {
			try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
			let p12Copy = dir.appendingPathComponent("c.p12")
			let provisionCopy = dir.appendingPathComponent("c.mobileprovision")
			try fm.copyItem(at: p12, to: p12Copy)
			try fm.copyItem(at: provision, to: provisionCopy)
			return FR.checkPasswordForCertificate(for: p12Copy, with: password, using: provisionCopy) ? .ok : .wrong
		} catch {
			return .unverifiable
		}
	}

	static let missingPasswordMessage = String.localized("This certificate's password is not on this device. Re-enter the password in the certificate details.")
}
