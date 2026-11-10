//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift
import OSLog

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	
	var packageUrl: URL?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?
	/// Fully Local only: transparent TCP relay that logs connections and the TLS handshake.
	private var _relay: InstallDiagnosticProxy?
	private var _observers: [NSObjectProtocol] = []

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) throws {
		self.app = app
		self.viewModel = viewModel
		_beginLog()
		try _setup()
		try _configureRoutes()
		try _server?.server.start()
		_needsShutdown = true
		_startRelayIfNeeded()
	}
	
	deinit {
		_shutdownServer()
		_observers.forEach { NotificationCenter.default.removeObserver($0) }
	}
	
	private var _isFullyLocal: Bool {
		getServerMethod() != 1
	}
	
	private func _setup() throws {
		do {
			self._server = try setupApp(port: port, behindRelay: _isFullyLocal)
		} catch {
			Logger.misc.error("Server setup failed: \(error.localizedDescription)")
			InstallServerLog.shared.add("Server setup failed: \(String(describing: error))")
			DispatchQueue.main.async {
				self.viewModel.status = .broken(error)
			}
		}
	}
	
	// MARK: Diagnostics
	
	private func _beginLog() {
		let log = InstallServerLog.shared
		log.reset()
		log.add("Install server: \(_isFullyLocal ? "Fully Local (HTTPS)" : "Semi Local (HTTP)"), port \(port), host \(sni())")
		log.add("iOS \(UIDevice.current.systemVersion), app \(app.identifier ?? "?") \(app.version ?? "")")
		if _isFullyLocal {
			log.add(Self.localCADescription())
		}
		
		// The installer daemons can only connect while the app (and its server) is alive.
		let center = NotificationCenter.default
		let events: [(Notification.Name, String)] = [
			(UIApplication.didEnterBackgroundNotification, "app entered background"),
			(UIApplication.willEnterForegroundNotification, "app will enter foreground"),
			(UIApplication.willResignActiveNotification, "app will resign active"),
			(UIApplication.didBecomeActiveNotification, "app became active")
		]
		_observers = events.map { name, text in
			center.addObserver(forName: name, object: nil, queue: nil) { _ in
				InstallServerLog.shared.add(text)
			}
		}
	}
	
	private func _startRelayIfNeeded() {
		guard _isFullyLocal, let server = _server else { return }
		
		do {
			guard let internalPort = server.http.server.shared.localAddress?.port else {
				throw Abort(.internalServerError, reason: "internal server port unknown")
			}
			let relay = InstallDiagnosticProxy(group: server.eventLoopGroup)
			try relay.start(port: port, targetPort: internalPort)
			_relay = relay
		} catch {
			Logger.misc.error("Install relay failed: \(error.localizedDescription)")
			InstallServerLog.shared.add("Relay could not listen on port \(port): \(String(describing: error))")
			DispatchQueue.main.async {
				self.viewModel.status = .broken(error)
			}
		}
	}
		
	private func _configureRoutes() throws {
		_server?.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case plistEndpoint.path:
				self._updateStatus(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				guard let packageUrl = packageUrl else {
					return Response(status: .notFound)
				}
				
				self._updateStatus(.sendingPayload)
				
				return req.fileio.streamFile(
					at: packageUrl.path
				) { result in
					switch result {
					case .success:
						self._updateStatus(.installing)
					case .failure(let error):
						self._updateStatus(.broken(error))
					}

				}
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	private func _shutdownServer() {
		guard _needsShutdown else { return }
		
		_needsShutdown = false
		_relay?.stop()
		_relay = nil
		_server?.server.shutdown()
		_server?.shutdown()
		InstallServerLog.shared.add("Install server stopped")
	}
	
	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		InstallServerLog.shared.add("Status: \(String(describing: newStatus))")
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}
		
	func getServerMethod() -> Int {
		UserDefaults.standard.integer(forKey: "Quill.serverMethod")
	}
	
	func getIPFix() -> Bool {
		UserDefaults.standard.bool(forKey: "Quill.ipFix")
	}
}
