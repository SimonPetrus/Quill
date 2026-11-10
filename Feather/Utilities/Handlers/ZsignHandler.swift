//
//  ZsignHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import Zsign
import UIKit

final class ZsignHandler {
	var hadError: Error?
	
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

		let success = Zsign.sign(
			appPath: _appUrl.relativePath,
			provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
			p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
			p12Password: cert.resolvedPassword,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			removeProvision: _options.removeProvisioning
		)
		try _throwIfFailed(success)
	}
	
	func adhocSign() async throws {
		let success = Zsign.sign(
			appPath: _appUrl.relativePath,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			adhoc: true,
			removeProvision: _options.removeProvisioning
		)
		try _throwIfFailed(success)
	}
	
	/// zsign reports every failure through its return value (wrong password, profile/certificate
	/// mismatch, unsigned nested code...). Throw before the app is moved and added to the library,
	/// so an unsigned app is never listed as signed.
	private func _throwIfFailed(_ success: Bool) throws {
		guard !success else { return }
		// read synchronously right after `sign`: the error is kept per thread
		let error = SigningFileHandlerError.signFailedWithReason(Zsign.lastError)
		hadError = error
		throw error
	}
}
