//
//  InstallServerLog.swift
//  Feather
//
//  In-memory ring buffer with the diagnostic log of the last install server
//  (connections, TLS handshake, HTTP requests, server lifecycle).
//  Nothing is written to disk; key material is never logged.
//

import Foundation
import Combine
import Vapor
import Logging

// MARK: - Class
final class InstallServerLog: ObservableObject {
	static let shared = InstallServerLog()

	private let _capacity = 200
	private let _lock = NSLock()
	private var _lines: [String] = []
	private var _notifyScheduled = false
	private let _formatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "HH:mm:ss.SSS"
		return formatter
	}()

	private init() {}

	// MARK: Public

	/// Starts a new log (the previous install's lines are dropped).
	func reset() {
		_lock.lock()
		_lines.removeAll()
		_lock.unlock()
		_scheduleNotify()
	}

	/// Thread safe, may be called from any event loop.
	func add(_ message: String) {
		let flat = message
			.replacingOccurrences(of: "\r", with: " ")
			.replacingOccurrences(of: "\n", with: " | ")

		_lock.lock()
		_lines.append("\(_formatter.string(from: Date())) \(flat)")
		if _lines.count > _capacity {
			_lines.removeFirst(_lines.count - _capacity)
		}
		_lock.unlock()
		_scheduleNotify()
	}

	var lines: [String] {
		_lock.lock()
		defer { _lock.unlock() }
		return _lines
	}

	var text: String {
		lines.joined(separator: "\n")
	}

	// MARK: Notify

	/// Coalesces UI updates (many lines may arrive within a few milliseconds).
	private func _scheduleNotify() {
		_lock.lock()
		let shouldSchedule = !_notifyScheduled
		_notifyScheduled = true
		_lock.unlock()

		guard shouldSchedule else { return }

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
			self._lock.lock()
			self._notifyScheduled = false
			self._lock.unlock()
			self.objectWillChange.send()
		}
	}
}

// MARK: - Vapor log handler
/// Attached only to the install server's `Application.logger` / HTTP server logger
/// (not bootstrapped globally), so Vapor's own server messages end up in the ring buffer.
struct InstallServerLogHandler: LogHandler {
	var metadata: Logging.Logger.Metadata = [:]
	var logLevel: Logging.Logger.Level = .debug

	subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
		get { metadata[key] }
		set { metadata[key] = newValue }
	}

	func log(
		level: Logging.Logger.Level,
		message: Logging.Logger.Message,
		metadata: Logging.Logger.Metadata?,
		source: String,
		file: String,
		function: String,
		line: UInt
	) {
		// Requests are logged by InstallServerLogMiddleware with more detail.
		if file.hasSuffix("RouteLoggingMiddleware.swift") {
			return
		}
		InstallServerLog.shared.add("[vapor \(level)] \(message)")
	}
}

// MARK: - HTTP middleware
/// Logs every HTTP request reaching the install server (including 404s).
struct InstallServerLogMiddleware: Middleware {
	func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
		let path = request.url.path
		let userAgent = request.headers.first(name: .userAgent) ?? "-"
		let remote = request.remoteAddress.map { "\($0)" } ?? "?"

		InstallServerLog.shared.add("HTTP → \(request.method.rawValue) \(path) \(request.version) from \(remote) UA=\(userAgent)")

		return next.respond(to: request).map { response in
			InstallServerLog.shared.add("HTTP ← \(response.status.code) \(path)")
			return response
		}.flatMapErrorThrowing { error in
			InstallServerLog.shared.add("HTTP ← error \(path): \(String(describing: error))")
			throw error
		}
	}
}
