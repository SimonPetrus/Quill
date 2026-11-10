//
//  Server+TLS.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import NIOSSL
import NIOTLS
import Vapor
import Logging
import SystemConfiguration.CaptiveNetwork

// MARK: - Class extension: TLS/Setup
extension ServerInstaller {
	// MARK: Setup
	static let env: Environment = {
		var env = try! Environment.detect()
		try! LoggingSystem.bootstrap(from: &env)
		return env
	}()
	
	/// - Parameter diagnostics: Diagnostic mode (off by default). Off: exactly the
	///   original setup. On: install log logger + middleware, and in Fully Local Vapor
	///   listens on a random loopback port behind `InstallDiagnosticProxy` (public `port`).
	func setupApp(port: Int, diagnostics: Bool = false) throws -> Application {
		let app = Application(Self.env)
		app.threadPool = .init(numberOfThreads: 1)
		
		let behindRelay = diagnostics && getServerMethod() != 1
		
		if diagnostics {
			// Install server only (not global): Vapor's own messages also go to the install log.
			var logger = Logging.Logger(label: "quill.install-server") { _ in InstallServerLogHandler() }
			logger.logLevel = .debug
			app.logger = logger
			app.http.server.configuration.logger = logger
			app.middleware.use(InstallServerLogMiddleware(), at: .beginning)
		}
		
		if getServerMethod() != 1 {
			// Key log only feeds the in-memory TLS sniffer of the relay, it does not change the handshake.
			var keyLog: NIOSSLKeyLogCallback?
			if behindRelay {
				keyLog = { (line: ByteBuffer) in
					TLSKeyLogStore.shared.add(line)
				}
			}
			if let tls = try Self.tls(keyLog: keyLog) {
				app.http.server.configuration.tlsConfiguration = tls
			}
		}
		
		app.http.server.configuration.hostname = sni()
		app.http.server.configuration.tcpNoDelay = true
		if behindRelay {
			app.http.server.configuration.address = .hostname("127.0.0.1", port: 0)
		} else {
			app.http.server.configuration.address = .hostname("0.0.0.0", port: port)
			app.http.server.configuration.port = port
		}
		app.routes.defaultMaxBodySize = "128mb"
		app.routes.caseInsensitive = false
		
		return app
	}
	
	// MARK: Files/IP
	func sni() -> String {
		let localhost = "127.0.0.1"
		
		if getServerMethod() == 1 {
			return !self.getIPFix()
				? (Self.getLocalAddress() ?? localhost)
				: localhost
		} else {
			// Fully Local: IPv4 loopback literal (IP SAN of the server certificate).
			// The server only listens on IPv4 (0.0.0.0) and the installer daemons may
			// resolve "localhost" to ::1 first, which fails with "Cannot connect".
			return Self.localAddress
		}
	}
	
	static func tls(keyLog: NIOSSLKeyLogCallback? = nil) throws -> TLSConfiguration? {
		let (crt, pem) = try Self.createServerCert()
		
		var configuration = try TLSConfiguration.makeServerConfiguration(
			certificateChain: NIOSSLCertificate.fromPEMFile(crt.path).map {
				NIOSSLCertificateSource.certificate($0)
			},
			privateKey: .privateKey(
				try NIOSSLPrivateKey(file: pem.path, format: .pem)
			)
		)
		if let keyLog {
			configuration.keyLogCallback = keyLog
		}
		return configuration
	}
}

extension ServerInstaller {
	static func getLocalAddress() -> String? {
		var address: String?
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		
		if getifaddrs(&ifaddr) == 0 {
			var ptr = ifaddr
			while ptr != nil {
				let interface = ptr!.pointee
				let addrFamily = interface.ifa_addr.pointee.sa_family
				
				if addrFamily == UInt8(AF_INET) {
					
					let name = String(cString: interface.ifa_name)
					if name == "en0" || name == "pdp_ip0" {
						
						var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
						if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
						               &hostname, socklen_t(hostname.count),
						               nil, socklen_t(0), NI_NUMERICHOST) == 0 {
							address = String(cString: hostname)
						}
						
					}
				}
				ptr = ptr!.pointee.ifa_next
			}
			freeifaddrs(ifaddr)
		}
		
		return address
	}
}
