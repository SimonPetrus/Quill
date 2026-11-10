//
//  LocalConnectionTester.swift
//  Feather
//
//  Diagnostic for Fully Local: starts a short-lived HTTPS server with the same
//  TLS configuration as the install server and requests it over 127.0.0.1 and
//  localhost using the default system trust.
//

import Foundation
import Vapor
import OSLog

// MARK: - Class
enum LocalConnectionTester {
	static let hosts = [ServerInstaller.localAddress, ServerInstaller.localHostname]

	private static let _pingPath = "ping"
	private static let _pingBody = "ok"

	// MARK: Public

	/// Runs the test and returns one line per host.
	static func run() async -> [String] {
		let app: Application
		let port: Int

		do {
			(app, port) = try _startServer()
		} catch {
			Logger.misc.error("Connection test: server could not be started: \(String(describing: error), privacy: .public)")
			return [String.localized("Test server could not be started") + ": " + _describe(error)]
		}

		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 5
		configuration.timeoutIntervalForResource = 10
		configuration.waitsForConnectivity = false
		// Default delegate: the system decides about trust, nothing is relaxed here.
		let session = URLSession(configuration: configuration)

		var lines: [String] = []
		for host in hosts {
			lines.append("\(host): " + (await _ping(session: session, host: host, port: port)))
		}

		session.invalidateAndCancel()
		_shutdown(app)
		return lines
	}

	// MARK: Request

	private static func _ping(session: URLSession, host: String, port: Int) async -> String {
		var comps = URLComponents()
		comps.scheme = "https"
		comps.host = host
		comps.port = port
		comps.path = "/\(_pingPath)"

		guard let url = comps.url else {
			return String.localized("Unexpected response")
		}

		do {
			let (data, response) = try await session.data(from: url)
			let status = (response as? HTTPURLResponse)?.statusCode ?? 0

			guard status == 200, String(decoding: data, as: UTF8.self) == _pingBody else {
				Logger.misc.error("Connection test \(url.absoluteString, privacy: .public): unexpected response, HTTP \(status)")
				return String.localized("Unexpected response") + " (HTTP \(status))"
			}

			Logger.misc.info("Connection test \(url.absoluteString, privacy: .public): OK")
			return String.localized("Connected")
		} catch {
			Logger.misc.error("Connection test \(url.absoluteString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
			return _describe(error)
		}
	}

	/// Short description + error domain and code, e.g. "Could not connect (NSURLErrorDomain -1004)".
	private static func _describe(_ error: Error) -> String {
		let nsError = error as NSError
		let summary: String

		if nsError.domain == NSURLErrorDomain {
			switch nsError.code {
			case NSURLErrorCannotConnectToHost:
				summary = .localized("Could not connect")
			case NSURLErrorTimedOut:
				summary = .localized("Timed out")
			case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
				summary = .localized("Host not found")
			case NSURLErrorServerCertificateUntrusted,
				 NSURLErrorServerCertificateHasUnknownRoot,
				 NSURLErrorServerCertificateHasBadDate,
				 NSURLErrorServerCertificateNotYetValid:
				summary = .localized("Certificate not trusted")
			case NSURLErrorSecureConnectionFailed,
				 NSURLErrorClientCertificateRejected,
				 NSURLErrorClientCertificateRequired:
				summary = .localized("TLS handshake failed")
			case NSURLErrorAppTransportSecurityRequiresSecureConnection:
				summary = .localized("Blocked by App Transport Security")
			default:
				summary = nsError.localizedDescription
			}
		} else {
			summary = nsError.localizedDescription
		}

		return "\(summary) (\(nsError.domain) \(nsError.code))"
	}

	// MARK: Server

	/// Same TLS configuration and binding as the Fully Local install server.
	private static func _startServer() throws -> (Application, Int) {
		var lastError: Error = CocoaError(.fileWriteUnknown)

		for _ in 0..<5 {
			let port = Int.random(in: 4000...8000)
			// Reuses the shared environment, logging is bootstrapped only once.
			let app = Application(ServerInstaller.env)
			app.threadPool = .init(numberOfThreads: 1)

			do {
				if let tls = try ServerInstaller.tls() {
					app.http.server.configuration.tlsConfiguration = tls
				}
			} catch {
				_shutdown(app)
				throw error
			}

			app.http.server.configuration.tcpNoDelay = true
			app.http.server.configuration.address = .hostname("0.0.0.0", port: port)
			app.http.server.configuration.port = port

			app.get(.constant(_pingPath)) { _ -> Response in
				Response(status: .ok, headers: [
					"Content-Type": "text/plain",
					"Cache-Control": "no-store"
				], body: .init(string: _pingBody))
			}

			do {
				try app.server.start()
				return (app, port)
			} catch {
				lastError = error
				_shutdown(app)
			}
		}

		throw lastError
	}

	private static func _shutdown(_ app: Application) {
		DispatchQueue.global(qos: .utility).async {
			app.server.shutdown()
			app.shutdown()
		}
	}
}
