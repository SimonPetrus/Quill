//
//  FileManager+documents.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import Foundation.NSFileManager

extension FileManager {
	/// Gives apps Signed directory
	var archives: URL {
		URL.documentsDirectory.appendingPathComponent("Archives")
	}
	
	/// Gives apps Signed directory
	var signed: URL {
		URL.documentsDirectory.appendingPathComponent("Signed")
	}
	
	/// Gives apps Signed directory with a UUID appending path
	func signed(_ uuid: String) -> URL {
		signed.appendingPathComponent(uuid)
	}
	
	/// Gives apps Unsigned directory
	var unsigned: URL {
		URL.documentsDirectory.appendingPathComponent("Unsigned")
	}
	
	/// Gives apps Unsigned directory with a UUID appending path
	func unsigned(_ uuid: String) -> URL {
		unsigned.appendingPathComponent(uuid)
	}
	
	/// OLD certificates directory (Documents, visible in Files). Only read for legacy data and migration.
	var certificates: URL {
		URL.documentsDirectory.appendingPathComponent("Certificates")
	}
	/// Gives apps Certificates directory with a UUID appending path
	func certificates(_ uuid: String) -> URL {
		certificates.appendingPathComponent(uuid)
	}
	
	/// Certificates directory in Application Support (not visible in Files, file protection applied).
	var secureCertificates: URL {
		URL.applicationSupportDirectory
			.appendingPathComponent("Quill", isDirectory: true)
			.appendingPathComponent("Certificates", isDirectory: true)
	}
	func secureCertificates(_ uuid: String) -> URL {
		secureCertificates.appendingPathComponent(uuid)
	}
	
	/// Directories that can hold a certificate's files, in lookup order: new location first, then the legacy one.
	func certificateDirectories(_ uuid: String) -> [URL] {
		[secureCertificates(uuid), certificates(uuid)]
	}
	
	/// Creates a certificate directory (with intermediates) using the certificate file protection.
	func createSecureCertificateDirectory(_ url: URL) throws {
		try createDirectory(
			at: url,
			withIntermediateDirectories: true,
			attributes: [.protectionKey: FileManager.certificateProtection]
		)
	}
	
	/// Not `.complete`: signing runs while the device is locked (background audio keeps the app alive) and
	/// `.complete` files cannot be opened then (`.completeUnlessOpen` neither: new opens fail when locked).
	/// `completeUntilFirstUserAuthentication` is encrypted at rest and readable after the first unlock.
	static let certificateProtection = FileProtectionType.completeUntilFirstUserAuthentication
	
	/// Applies the certificate file protection to a file or directory. Never sets isExcludedFromBackup.
	func protectCertificateItem(at url: URL) {
		try? setAttributes([.protectionKey: FileManager.certificateProtection], ofItemAtPath: url.path)
	}
}
