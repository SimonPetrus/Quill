//
//  LocalCAInstaller.swift
//  Feather
//
//  Serves the local root CA as a configuration profile over a short-lived,
//  plain HTTP server bound to 127.0.0.1 and opens it in Safari.
//

import Foundation
import Vapor
import UIKit
import Crypto

// MARK: - Class
final class LocalCAInstaller {
	static let shared = LocalCAInstaller()

	private let _profilePath = "FeatherLocalCA.mobileconfig"
	private let _timeout: TimeInterval = 60
	private let _graceAfterServe: TimeInterval = 5

	// Touched on the main thread only.
	private var _app: Application?
	private var _backgroundTask: UIBackgroundTaskIdentifier = .invalid
	private var _generation = 0

	private init() {}

	// MARK: Public

	/// Starts the temporary server and opens the profile in Safari.
	func install() throws {
		dispatchPrecondition(condition: .onQueue(.main))
		stop()

		let der = try ServerInstaller.rootCertificateDER()
		let profile = try Self.makeProfile(rootDER: der)

		_generation += 1
		let generation = _generation
		
		let (app, port) = try _startServer(profile: profile, generation: generation)
		_app = app

		_backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FeatherLocalCA") { [weak self] in
			self?.stop()
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + _timeout) { [weak self] in
			guard let self, self._generation == generation else { return }
			self.stop()
		}

		guard let url = URL(string: "http://127.0.0.1:\(port)/\(_profilePath)") else {
			stop()
			throw CocoaError(.fileReadInvalidFileName)
		}

		UIApplication.shared.open(url) { [weak self] success in
			if !success {
				self?.stop()
			}
		}
	}

	// MARK: Server

	private func _startServer(profile: Data, generation: Int) throws -> (Application, Int) {
		var lastError: Error = CocoaError(.fileWriteUnknown)

		for _ in 0..<5 {
			let port = Int.random(in: 4000...8000)
			// Reuses the shared environment, logging is bootstrapped only once.
			let app = Application(ServerInstaller.env)
			app.threadPool = .init(numberOfThreads: 1)
			app.http.server.configuration.hostname = "127.0.0.1"
			app.http.server.configuration.address = .hostname("127.0.0.1", port: port)
			app.http.server.configuration.port = port
			app.http.server.configuration.tcpNoDelay = true

			let grace = _graceAfterServe

			app.get("FeatherLocalCA.mobileconfig") { [weak self] _ -> Response in
				DispatchQueue.main.asyncAfter(deadline: .now() + grace) {
					// Ignore if a newer install session replaced this one.
					guard let self, self._generation == generation else { return }
					self.stop()
				}
				return Response(status: .ok, headers: [
					"Content-Type": "application/x-apple-aspen-config",
					"Cache-Control": "no-store"
				], body: .init(data: profile))
			}

			do {
				try app.server.start()
				return (app, port)
			} catch {
				lastError = error
				Self._shutdown(app)
			}
		}

		throw lastError
	}

	// MARK: Stop

	func stop() {
		dispatchPrecondition(condition: .onQueue(.main))
		_generation += 1

		if let app = _app {
			_app = nil
			Self._shutdown(app)
		}

		if _backgroundTask != .invalid {
			UIApplication.shared.endBackgroundTask(_backgroundTask)
			_backgroundTask = .invalid
		}
	}

	private static func _shutdown(_ app: Application) {
		DispatchQueue.global(qos: .utility).async {
			app.server.shutdown()
			app.shutdown()
		}
	}

	// MARK: Profile

	/// Deterministic (name-based) UUID derived from the root CA, so a renewed CA yields a new profile.
	private static func _uuid(salt: String, rootDER: Data) -> String {
		var bytes = Array(SHA256.hash(data: Data(salt.utf8) + rootDER)).prefix(16).map { $0 }
		bytes[6] = (bytes[6] & 0x0F) | 0x50
		bytes[8] = (bytes[8] & 0x3F) | 0x80
		return UUID(uuid: (
			bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
			bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
		)).uuidString
	}
	
	static func makeProfile(rootDER: Data) throws -> Data {
		let bundleID = Bundle.main.bundleIdentifier ?? "feather"
		
		let rootPayload: [String: Any] = [
			"PayloadType": "com.apple.security.root",
			"PayloadVersion": 1,
			"PayloadIdentifier": "\(bundleID).localca.root",
			"PayloadUUID": _uuid(salt: "root", rootDER: rootDER),
			"PayloadDisplayName": "Feather Local Root CA",
			"PayloadContent": rootDER
		]
		
		let profile: [String: Any] = [
			"PayloadType": "Configuration",
			"PayloadVersion": 1,
			"PayloadIdentifier": "\(bundleID).localca",
			"PayloadUUID": _uuid(salt: "profile", rootDER: rootDER),
			"PayloadDisplayName": "Feather Local CA",
			"PayloadDescription": "Root certificate used by Feather to install apps from this device (localhost only).",
			"PayloadContent": [rootPayload]
		]

		return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
	}

}
