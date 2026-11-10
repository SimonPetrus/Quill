//
//  CertificatePairValidator.swift
//  Quill
//
//  Checks that a .p12 certificate actually belongs to a .mobileprovision profile.
//  Zsign only verifies the p12 password; it never checks that the profile lists the
//  certificate, so signing "succeeds" and iOS then rejects the install.
//

import Foundation
import Security
import OSLog
import X509
import UIKit
import NimbleExtensions

// MARK: - Result
enum CertificatePairValidationResult: Equatable {
	case ok
	/// The p12 certificate is not in the profile's `DeveloperCertificates`.
	case notInProfile
	case certificateExpired(Date)
	case profileExpired(Date)
	case teamMismatch(cert: String, profile: String)
	/// Could not be checked (unsupported p12, unreadable profile, ...). Never blocks.
	case unreadable(String)
	
	/// Results that must stop import / signing.
	var isBlocking: Bool {
		switch self {
		case .notInProfile: return true
		default: return false
		}
	}
}

// MARK: - Validator
enum CertificatePairValidator {
	static func validate(p12URL: URL, password: String, provisionURL: URL) -> CertificatePairValidationResult {
		guard let p12Data = try? Data(contentsOf: p12URL) else {
			return .unreadable("p12 file could not be read")
		}
		return validate(p12Data: p12Data, password: password, provisionURL: provisionURL)
	}
	
	static func validate(p12Data: Data, password: String, provisionURL: URL) -> CertificatePairValidationResult {
		guard let profile = CertificateReader(provisionURL).decoded else {
			return .unreadable("provisioning profile could not be decoded")
		}
		
		let now = Date()
		let ders = _certificateDERs(p12Data: p12Data, password: password)
		guard !ders.isEmpty else {
			// p12 unreadable, but an expired profile can still be reported.
			if profile.ExpirationDate < now { return .profileExpired(profile.ExpirationDate) }
			return .unreadable("certificate could not be extracted from p12")
		}
		
		// (a) one of the p12 identities must be listed in the profile
		guard let profileCerts = profile.DeveloperCertificates, !profileCerts.isEmpty else {
			return .unreadable("profile has no DeveloperCertificates")
		}
		guard let certDER = ders.first(where: { profileCerts.contains($0) }) else {
			return .notInProfile
		}
		
		// (c) team id: certificate subject OU vs profile TeamIdentifier
		var parsed: X509.Certificate?
		do {
			parsed = try X509.Certificate(derEncoded: Array(certDER))
		} catch {
			Logger.misc.error("Certificate DER parse failed: \(error.localizedDescription, privacy: .public)")
		}
		
		if
			let parsed,
			let certTeam = _teamID(from: parsed),
			let profileTeam = profile.TeamIdentifier.first,
			certTeam != profileTeam
		{
			return .teamMismatch(cert: certTeam, profile: profileTeam)
		}
		
		// (b) expiration
		if let parsed, parsed.notValidAfter < now {
			return .certificateExpired(parsed.notValidAfter)
		}
		if profile.ExpirationDate < now {
			return .profileExpired(profile.ExpirationDate)
		}
		
		return .ok
	}
	
	// MARK: Helpers
	/// DER of every identity's certificate in the p12.
	private static func _certificateDERs(p12Data: Data, password: String) -> [Data] {
		var options: [String: Any] = [kSecImportExportPassphrase as String: password]
		var inMemory = false
		// Avoid leaving identities in the keychain where the OS supports it (iOS 18+).
		if #available(iOS 18.0, *) {
			options[kSecImportToMemoryOnly as String] = true
			inMemory = true
		}
		var items: CFArray?
		let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
		guard status == errSecSuccess else {
			Logger.misc.error("SecPKCS12Import failed: \(status, privacy: .public)")
			return []
		}
		
		var result: [Data] = []
		for item in (items as? [[String: Any]]) ?? [] {
			guard let identityRef = item[kSecImportItemIdentity as String] else { continue }
			let identity = identityRef as! SecIdentity
			var cert: SecCertificate?
			if SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert {
				result.append(SecCertificateCopyData(cert) as Data)
			}
			if !inMemory {
				_removeFromKeychain(identity)
			}
		}
		return result
	}
	
	/// iOS < 18 persists imported identities; remove identity, certificate and private key again.
	private static func _removeFromKeychain(_ identity: SecIdentity) {
		func delete(_ query: [String: Any], _ what: String) {
			let status = SecItemDelete(query as CFDictionary)
			if status != errSecSuccess && status != errSecItemNotFound {
				Logger.misc.warning("Keychain cleanup (\(what)) failed: \(status, privacy: .public)")
			}
		}
		delete([kSecValueRef as String: identity], "identity")
		var cert: SecCertificate?
		if SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert {
			delete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert], "certificate")
		}
		var key: SecKey?
		if SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key {
			delete([kSecClass as String: kSecClassKey, kSecValueRef as String: key], "key")
		}
	}
	
	/// Apple development/distribution certificates carry the Team ID in subject OU.
	private static func _teamID(from cert: X509.Certificate) -> String? {
		let subject = String(describing: cert.subject)
		guard let range = subject.range(of: #"(?<![A-Z0-9])OU=([A-Z0-9]{10})(?![A-Z0-9])"#, options: .regularExpression) else {
			return nil
		}
		return String(subject[range].dropFirst(3))
	}
}

// MARK: - Alerts
extension CertificatePairValidator {
	/// Validates off the main thread, then calls back on the main thread:
	/// `proceed` for ok / unreadable / confirmed warnings, `cancel` when blocked or the user backs out.
	static func check(
		p12URL: URL,
		password: String,
		provisionURL: URL,
		continueTitle: String,
		proceed: @escaping () -> Void,
		cancel: @escaping () -> Void
	) {
		DispatchQueue.global(qos: .userInitiated).async {
			let result = validate(p12URL: p12URL, password: password, provisionURL: provisionURL)
			DispatchQueue.main.async {
				if case .unreadable(let reason) = result {
					// Could not verify: never block.
					Logger.misc.warning("Certificate/profile check skipped: \(reason, privacy: .public)")
				}
				presentAlert(for: result, continueTitle: continueTitle, onContinue: proceed, onCancel: cancel)
			}
		}
	}
	
	/// Presents the alert for a non-ok result.
	/// - Parameters:
	///   - continueTitle: title of the "proceed anyway" button, shown only for expiry warnings.
	///   - onContinue: called if the user proceeds despite a warning.
	///   - onCancel: called when the alert is dismissed without proceeding.
	@MainActor
	static func presentAlert(
		for result: CertificatePairValidationResult,
		continueTitle: String,
		onContinue: @escaping () -> Void,
		onCancel: (() -> Void)? = nil
	) {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .none
		
		switch result {
		case .notInProfile:
			UIAlertController.showAlertWithOk(
				title: String.localized("Certificate Mismatch"),
				message: String.localized("This certificate does not belong to this provisioning profile.")
					+ "\n\n" + String.localized("The profile was created with a different certificate, so iOS would reject the app during installation. Use the certificate the profile was created with, or create a new profile for this certificate.")
			) { onCancel?() }
		case .teamMismatch(let cert, let profile):
			_warn(
				title: String.localized("Certificate Mismatch"),
				message: String.localized("This certificate does not belong to this provisioning profile.")
					+ "\n\n" + String(format: String.localized("The certificate's Team ID (%@) is different from the profile's Team ID (%@)."), cert, profile),
				continueTitle: continueTitle,
				onContinue: onContinue,
				onCancel: onCancel
			)
		case .certificateExpired(let date):
			_warn(
				title: String.localized("Certificate Expired"),
				message: String(format: String.localized("This certificate expired on %@."), formatter.string(from: date)),
				continueTitle: continueTitle,
				onContinue: onContinue,
				onCancel: onCancel
			)
		case .profileExpired(let date):
			_warn(
				title: String.localized("Provisioning Profile Expired"),
				message: String(format: String.localized("This provisioning profile expired on %@."), formatter.string(from: date)),
				continueTitle: continueTitle,
				onContinue: onContinue,
				onCancel: onCancel
			)
		case .ok, .unreadable:
			onContinue()
		}
	}
	
	@MainActor
	private static func _warn(title: String, message: String, continueTitle: String, onContinue: @escaping () -> Void, onCancel: (() -> Void)?) {
		UIAlertController.showAlert(
			title: title,
			message: message,
			actions: [
				UIAlertAction(title: continueTitle, style: .destructive) { _ in onContinue() },
				UIAlertAction(title: String.localized("Cancel"), style: .cancel) { _ in onCancel?() }
			]
		)
	}
}
