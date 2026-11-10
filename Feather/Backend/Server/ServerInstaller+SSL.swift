//
//  ServerInstaller+SSL.swift
//  Feather
//
//  Created by samsam on 10/6/26.
//
//  Based on claration/Feather PR #726 by Nyasami.
//  Extended: name-constrained root CA, private storage, renewal, trust check.
//

import Foundation
import Crypto
import SwiftASN1
import X509
import Security

// MARK: - Local CA (generated on device, replaces the expired backloop.dev certificate)
extension ServerInstaller {
	/// DNS name in the server certificate SAN.
	static let localHostname = "localhost"
	/// Host used by Fully Local mode endpoints (IP SAN of the server certificate).
	static let localAddress = "127.0.0.1"
	/// Extra SAN kept from the original PR.
	static let serverHostname = "quill.localhost"

	private static let _caLock = NSLock()
	private static let _renewWindow: TimeInterval = 60 * 60 * 24 * 30
	private static let _clockSkew: TimeInterval = 60 * 60

	/// Not shared with the Files app and excluded from backups (private keys live here).
	static var localCADirectory: URL {
		URL.applicationSupportDirectory
			.appendingPathComponent("Quill", isDirectory: true)
			.appendingPathComponent("LocalCA", isDirectory: true)
	}

	private static var _rootKeyURL: URL { localCADirectory.appendingPathComponent("root.key.pem") }
	private static var _rootCertURL: URL { localCADirectory.appendingPathComponent("root.cer") }
	private static var _serverCertURL: URL { localCADirectory.appendingPathComponent("server.crt.pem") }
	private static var _serverKeyURL: URL { localCADirectory.appendingPathComponent("server.key.pem") }

	// MARK: Public API

	/// Makes sure a valid root CA and server certificate exist (regenerating them when needed).
	@discardableResult
	static func createServerCert() throws -> (crt: URL, pem: URL) {
		_caLock.lock()
		defer { _caLock.unlock() }
		_ = try _ensureMaterial()
		return (_serverCertURL, _serverKeyURL)
	}

	/// DER of the root CA, to be installed by the user.
	static func rootCertificateDER() throws -> Data {
		_caLock.lock()
		defer { _caLock.unlock() }
		return try _ensureMaterial().root.der
	}

	/// Evaluates the server certificate with the system trust store (system + user installed + user trusted roots).
	static func isLocalCATrusted() -> Bool {
		_caLock.lock()
		defer { _caLock.unlock() }

		guard
			let material = try? _ensureMaterial(),
			let serverDER = try? _der(of: material.server),
			let serverCert = SecCertificateCreateWithData(nil, serverDER as CFData),
			let rootCert = SecCertificateCreateWithData(nil, material.root.der as CFData)
		else {
			return false
		}

		// Same host as the Fully Local endpoints: validates the IP SAN and the IP name constraint.
		let policy = SecPolicyCreateSSL(true, localAddress as CFString)
		var trust: SecTrust?
		guard
			SecTrustCreateWithCertificates([serverCert, rootCert] as CFArray, policy, &trust) == errSecSuccess,
			let trust
		else {
			return false
		}

		// No anchors set: evaluated against system + user installed/trusted roots.
		return SecTrustEvaluateWithError(trust, nil)
	}

	// MARK: Material

	private static func _ensureMaterial() throws -> (root: RootMaterialModel, server: X509.Certificate) {
		try _prepareDirectory()
		let root = try _rootMaterial()

		if let server = _validServerCertificate(root: root) {
			return (root, server)
		}

		let server = try _createServerCertificate(root: root)
		return (root, server)
	}

	private static func _prepareDirectory() throws {
		let fm = FileManager.default
		var dir = localCADirectory

		try fm.createDirectory(
			at: dir,
			withIntermediateDirectories: true,
			attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
		)
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try? dir.setResourceValues(values)

		// Leftovers: expired backloop.dev files (they were visible in Files).
		let leftovers = ["server.crt", "server.pem", "commonName.txt", "root.key", "\(LegacyMigration.legacyName)LocalCA.cer"]
		for name in leftovers {
			let url = URL.documentsDirectory.appendingPathComponent(name)
			if fm.fileExists(atPath: url.path) {
				try? fm.removeItem(at: url)
			}
		}
	}

	private static func _write(_ data: Data, to url: URL) throws {
		try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
	}

	private static func _der(of certificate: X509.Certificate) throws -> Data {
		var serializer = DER.Serializer()
		try serializer.serialize(certificate)
		return Data(serializer.serializedBytes)
	}

	// MARK: Root

	private static func _rootMaterial() throws -> RootMaterialModel {
		let now = Date()
		let name = try _rootName

		if
			let keyPEM = try? String(contentsOf: _rootKeyURL, encoding: .utf8),
			let p256 = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM),
			let der = try? Data(contentsOf: _rootCertURL),
			let certificate = try? X509.Certificate(derEncoded: Array(der))
		{
			let key = X509.Certificate.PrivateKey(p256)
			let hasNameConstraints = ((try? certificate.extensions.nameConstraints) ?? nil) != nil

			if
				certificate.publicKey == key.publicKey,
				certificate.subject == name,
				certificate.issuer == name,
				key.publicKey.isValidSignature(certificate.signature, for: certificate),
				certificate.notValidBefore <= now.addingTimeInterval(_clockSkew),
				certificate.notValidAfter > now.addingTimeInterval(_renewWindow),
				hasNameConstraints
			{
				return RootMaterialModel(privateKey: key, certificate: certificate, der: der)
			}
		}

		// Missing / mismatched / expiring root: new CA (user must install it again), old server cert is useless.
		try? FileManager.default.removeItem(at: _serverCertURL)
		try? FileManager.default.removeItem(at: _serverKeyURL)

		let p256 = P256.Signing.PrivateKey()
		let key = X509.Certificate.PrivateKey(p256)
		let certificate = try _createRootCA(key: key)
		let der = try _der(of: certificate)

		try _write(Data(p256.pemRepresentation.utf8), to: _rootKeyURL)
		try _write(der, to: _rootCertURL)
		return RootMaterialModel(privateKey: key, certificate: certificate, der: der)
	}

	private static var _rootName: DistinguishedName {
		get throws {
			try DistinguishedName {
				CommonName("Quill Local Root CA")
			}
		}
	}

	private static func _createRootCA(key: X509.Certificate.PrivateKey) throws -> X509.Certificate {
		let name = try _rootName
		let now = Date()

		// The CA may only ever vouch for localhost / 127.0.0.1, so a leaked key is of little use.
		let nameConstraints = NameConstraints(
			permittedDNSDomains: [localHostname],
			permittedIPRanges: [ASN1OctetString(contentBytes: [127, 0, 0, 1, 255, 255, 255, 255][...])]
		)

		let extensions = try X509.Certificate.Extensions {
			Critical(
				BasicConstraints.isCertificateAuthority(maxPathLength: 0)
			)
			Critical(
				KeyUsage(keyCertSign: true, cRLSign: true)
			)
			Critical(nameConstraints)
			SubjectKeyIdentifier(hash: key.publicKey)
		}

		return try X509.Certificate(
			version: .v3,
			serialNumber: X509.Certificate.SerialNumber(),
			publicKey: key.publicKey,
			notValidBefore: now.addingTimeInterval(-_clockSkew),
			notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 365 * 10),
			issuer: name,
			subject: name,
			signatureAlgorithm: .ecdsaWithSHA256,
			extensions: extensions,
			issuerPrivateKey: key
		)
	}

	// MARK: Server certificate

	/// Returns the stored server certificate only if it is still usable, otherwise nil.
	private static func _validServerCertificate(root: RootMaterialModel) -> X509.Certificate? {
		let now = Date()

		guard
			let certPEM = try? String(contentsOf: _serverCertURL, encoding: .utf8),
			let keyPEM = try? String(contentsOf: _serverKeyURL, encoding: .utf8),
			let certificate = try? X509.Certificate(pemEncoded: certPEM),
			let p256 = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM)
		else {
			return nil
		}

		guard
			certificate.issuer == root.certificate.subject,
			root.certificate.publicKey.isValidSignature(certificate.signature, for: certificate),
			certificate.publicKey == X509.Certificate.PrivateKey(p256).publicKey,
			certificate.notValidBefore <= now.addingTimeInterval(_clockSkew),
			certificate.notValidAfter > now.addingTimeInterval(_renewWindow),
			let sans = (try? certificate.extensions.subjectAlternativeNames) ?? nil,
			sans.contains(.dnsName(localHostname))
		else {
			return nil
		}

		return certificate
	}

	private static func _createServerCertificate(root: RootMaterialModel) throws -> X509.Certificate {
		let p256 = P256.Signing.PrivateKey()
		let serverPrivateKey = X509.Certificate.PrivateKey(p256)

		let name = try DistinguishedName {
			CommonName(localHostname)
		}

		let now = Date()

		let extensions = try X509.Certificate.Extensions {
			Critical(
				BasicConstraints.notCertificateAuthority
			)
			Critical(
				KeyUsage(digitalSignature: true)
			)
			try ExtendedKeyUsage([.serverAuth])
			SubjectAlternativeNames([
				.dnsName(localHostname),
				.dnsName(serverHostname),
				.ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1][...]))
			])
			SubjectKeyIdentifier(hash: serverPrivateKey.publicKey)
			AuthorityKeyIdentifier(keyIdentifier: SubjectKeyIdentifier(hash: root.certificate.publicKey).keyIdentifier)
		}

		// 365 days: below the 825 day limit iOS enforces on server certificates.
		let certificate = try X509.Certificate(
			version: .v3,
			serialNumber: X509.Certificate.SerialNumber(),
			publicKey: serverPrivateKey.publicKey,
			notValidBefore: now.addingTimeInterval(-_clockSkew),
			notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 365),
			issuer: root.certificate.subject,
			subject: name,
			signatureAlgorithm: .ecdsaWithSHA256,
			extensions: extensions,
			issuerPrivateKey: root.privateKey
		)

		try _write(Data(certificate.serializeAsPEM().pemString.utf8), to: _serverCertURL)
		try _write(Data(p256.pemRepresentation.utf8), to: _serverKeyURL)
		return certificate
	}
}
