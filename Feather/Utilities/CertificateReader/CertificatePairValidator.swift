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
		case .notInProfile, .teamMismatch: return true
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
		
		guard let certDER = _certificateDER(p12Data: p12Data, password: password) else {
			return .unreadable("certificate could not be extracted from p12")
		}
		
		// (a) the p12 certificate must be one of the profile's certificates
		if let profileCerts = profile.DeveloperCertificates, !profileCerts.isEmpty {
			if !profileCerts.contains(certDER) {
				return .notInProfile
			}
		} else {
			return .unreadable("profile has no DeveloperCertificates")
		}
		
		// (c) team id: certificate subject OU vs profile TeamIdentifier
		var parsed: X509.Certificate?
		do {
			parsed = try X509.Certificate(derEncoded: Array(certDER))
		} catch {
			Logger.misc.error("Certificate DER parse failed: \(error.localizedDescription)")
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
		let now = Date()
		if let parsed, parsed.notValidAfter < now {
			return .certificateExpired(parsed.notValidAfter)
		}
		if profile.ExpirationDate < now {
			return .profileExpired(profile.ExpirationDate)
		}
		
		return .ok
	}
	
	// MARK: Helpers
	private static func _certificateDER(p12Data: Data, password: String) -> Data? {
		let options: [String: Any] = [
			kSecImportExportPassphrase as String: password,
			kSecImportToMemoryOnly as String: true
		]
		var items: CFArray?
		let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
		guard status == errSecSuccess else {
			Logger.misc.error("SecPKCS12Import failed: \(status)")
			return nil
		}
		
		guard
			let first = (items as? [[String: Any]])?.first,
			let identityRef = first[kSecImportItemIdentity as String]
		else { return nil }
		
		let identity = identityRef as! SecIdentity
		var cert: SecCertificate?
		guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else {
			return nil
		}
		return SecCertificateCopyData(cert) as Data
	}
	
	/// Apple development/distribution certificates carry the Team ID in subject OU.
	private static func _teamID(from cert: X509.Certificate) -> String? {
		let subject = String(describing: cert.subject)
		guard let range = subject.range(of: #"OU=([A-Z0-9]{10})"#, options: .regularExpression) else {
			return nil
		}
		return String(subject[range].dropFirst(3))
	}
}

// MARK: - Alerts
extension CertificatePairValidator {
	/// Presents the alert for a non-ok result.
	/// - Parameters:
	///   - continueTitle: title of the "proceed anyway" button, shown only for expiry warnings.
	///   - onContinue: called if the user proceeds despite an expiry warning.
	@MainActor
	static func presentAlert(
		for result: CertificatePairValidationResult,
		continueTitle: String,
		onContinue: @escaping () -> Void
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
			)
		case .teamMismatch(let cert, let profile):
			UIAlertController.showAlertWithOk(
				title: String.localized("Certificate Mismatch"),
				message: String.localized("This certificate does not belong to this provisioning profile.")
					+ "\n\n" + String(format: String.localized("The certificate's Team ID (%@) is different from the profile's Team ID (%@)."), cert, profile)
			)
		case .certificateExpired(let date):
			_warn(
				title: String.localized("Certificate Expired"),
				message: String(format: String.localized("This certificate expired on %@."), formatter.string(from: date)),
				continueTitle: continueTitle,
				onContinue: onContinue
			)
		case .profileExpired(let date):
			_warn(
				title: String.localized("Provisioning Profile Expired"),
				message: String(format: String.localized("This provisioning profile expired on %@."), formatter.string(from: date)),
				continueTitle: continueTitle,
				onContinue: onContinue
			)
		case .ok, .unreadable:
			onContinue()
		}
	}
	
	@MainActor
	private static func _warn(title: String, message: String, continueTitle: String, onContinue: @escaping () -> Void) {
		UIAlertController.showAlert(
			title: title,
			message: message,
			actions: [
				UIAlertAction(title: continueTitle, style: .destructive) { _ in onContinue() },
				UIAlertAction(title: String.localized("Cancel"), style: .cancel, handler: nil)
			]
		)
	}
}
