//
//  InstallDiagnosticProxy.swift
//  Feather
//
//  Fully Local diagnostics. Vapor does not expose its channel pipeline and TLS
//  handshake failures never reach its logger (the HTTP handlers, and with them
//  the error logging, are only installed after ALPN, i.e. after a successful
//  handshake). So the install server listens behind a transparent TCP relay on
//  the public port: bytes are forwarded unchanged (TLS stays end to end between
//  the iOS installer and Vapor, same certificate, same ALPN), and the relay only
//  observes them to log accepted connections, the TLS handshake messages and
//  alerts (TLS 1.3 records are decrypted with the server's own key log, kept in
//  memory for the life of the connection and never written to the log).
//

import Foundation
import NIOCore
import NIOPosix
import Crypto

// MARK: - Relay
final class InstallDiagnosticProxy {
	private let _group: EventLoopGroup
	private var _channel: Channel?
	private let _lock = NSLock()
	private var _nextID = 0

	init(group: EventLoopGroup) {
		_group = group
	}

	/// Listens on `0.0.0.0:port` and relays every connection to `127.0.0.1:targetPort`.
	func start(port: Int, targetPort: Int) throws {
		let bootstrap = ServerBootstrap(group: _group)
			.serverChannelOption(ChannelOptions.backlog, value: 256)
			.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: SocketOptionValue(1))
			.childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: SocketOptionValue(1))
			.childChannelInitializer { [weak self] channel in
				let id = self?._makeID() ?? 0
				let remote = channel.remoteAddress.map { "\($0)" } ?? "?"
				let local = channel.localAddress.map { "\($0)" } ?? "?"
				InstallServerLog.shared.add("#\(id) TCP accepted from \(remote) on \(local)")

				return ClientBootstrap(group: channel.eventLoop)
					.channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: SocketOptionValue(1))
					.connect(host: "127.0.0.1", port: targetPort)
					.flatMapThrowing { upstream in
						// Both channels live on the same event loop (ClientBootstrap above).
						let connection = DiagnosticConnection(id: id)
						let (client, server) = DiagnosticGlueHandler.matchedPair(connection: connection)
						try upstream.pipeline.syncOperations.addHandler(server)
						try channel.pipeline.syncOperations.addHandler(client)
					}
					.flatMapError { error -> EventLoopFuture<Void> in
						InstallServerLog.shared.add("#\(id) internal server unreachable: \(String(describing: error))")
						return channel.eventLoop.makeFailedFuture(error)
					}
			}

		_channel = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
		InstallServerLog.shared.add("Relay listening on 0.0.0.0:\(port) → 127.0.0.1:\(targetPort)")
	}

	func stop() {
		_channel?.close(promise: nil)
		_channel = nil
		TLSKeyLogStore.shared.removeAll()
	}

	private func _makeID() -> Int {
		_lock.lock()
		defer { _lock.unlock() }
		_nextID += 1
		return _nextID
	}
}

// MARK: - Connection
/// Per connection state, only touched on the connection's event loop.
final class DiagnosticConnection {
	let id: Int
	let sniffer: TLSConnectionSniffer
	private let _started = Date()
	private var _bytes: [TLSConnectionSniffer.Direction: Int] = [.client: 0, .server: 0]
	private var _closed = false

	init(id: Int) {
		self.id = id
		self.sniffer = TLSConnectionSniffer(id: id)
	}

	func received(_ buffer: ByteBuffer, from side: TLSConnectionSniffer.Direction) {
		_bytes[side, default: 0] += buffer.readableBytes
		sniffer.feed(buffer, from: side)
	}

	func error(_ error: Error, on side: TLSConnectionSniffer.Direction) {
		InstallServerLog.shared.add("#\(id) \(side.name) socket error: \(String(describing: error))")
	}

	func closed(by side: TLSConnectionSniffer.Direction) {
		guard !_closed else { return }
		_closed = true

		let ms = Int(Date().timeIntervalSince(_started) * 1000)
		InstallServerLog.shared.add(
			"#\(id) closed by \(side.name) after \(ms) ms "
			+ "(client→server \(_bytes[.client] ?? 0) B, server→client \(_bytes[.server] ?? 0) B)"
		)
		InstallServerLog.shared.add("#\(id) verdict: \(sniffer.verdict)")
		sniffer.finish()
	}
}

// MARK: - Glue
/// Forwards bytes between the accepted socket and the internal Vapor socket,
/// with back pressure (reads are only issued while the partner is writable).
final class DiagnosticGlueHandler: ChannelDuplexHandler {
	typealias InboundIn = ByteBuffer
	typealias OutboundIn = ByteBuffer
	typealias OutboundOut = ByteBuffer

	/// Who sends the bytes read by this handler.
	private let _side: TLSConnectionSniffer.Direction
	private let _connection: DiagnosticConnection
	private var _partner: DiagnosticGlueHandler?
	private var _context: ChannelHandlerContext?
	private var _pendingRead = false

	private init(side: TLSConnectionSniffer.Direction, connection: DiagnosticConnection) {
		_side = side
		_connection = connection
	}

	static func matchedPair(connection: DiagnosticConnection) -> (client: DiagnosticGlueHandler, server: DiagnosticGlueHandler) {
		let client = DiagnosticGlueHandler(side: .client, connection: connection)
		let server = DiagnosticGlueHandler(side: .server, connection: connection)
		client._partner = server
		server._partner = client
		return (client, server)
	}

	// MARK: Partner

	private func _partnerWrite(_ buffer: ByteBuffer) {
		guard let context = _context else { return }
		context.write(wrapOutboundOut(buffer), promise: nil)
	}

	private func _partnerFlush() {
		_context?.flush()
	}

	/// Flushes what is already queued, then closes.
	private func _partnerClose() {
		guard let context = _context else { return }
		let channel = context.channel
		context.writeAndFlush(wrapOutboundOut(channel.allocator.buffer(capacity: 0))).whenComplete { _ in
			channel.close(promise: nil)
		}
	}

	private var _partnerWritable: Bool {
		_context?.channel.isWritable ?? false
	}

	private func _partnerBecameWritable() {
		if _pendingRead {
			_pendingRead = false
			_context?.read()
		}
	}

	// MARK: Handler

	func handlerAdded(context: ChannelHandlerContext) {
		_context = context
	}

	func handlerRemoved(context: ChannelHandlerContext) {
		_context = nil
		_partner = nil
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let buffer = unwrapInboundIn(data)
		_connection.received(buffer, from: _side)
		_partner?._partnerWrite(buffer)
	}

	func channelReadComplete(context: ChannelHandlerContext) {
		_partner?._partnerFlush()
	}

	func channelInactive(context: ChannelHandlerContext) {
		_connection.closed(by: _side)
		_partner?._partnerClose()
		context.fireChannelInactive()
	}

	func errorCaught(context: ChannelHandlerContext, error: Error) {
		_connection.error(error, on: _side)
		_partner?._partnerClose()
		context.close(promise: nil)
	}

	func channelWritabilityChanged(context: ChannelHandlerContext) {
		if context.channel.isWritable {
			_partner?._partnerBecameWritable()
		}
		context.fireChannelWritabilityChanged()
	}

	func read(context: ChannelHandlerContext) {
		if let partner = _partner, partner._partnerWritable {
			context.read()
		} else {
			_pendingRead = true
		}
	}
}

// MARK: - Key log
/// TLS secrets reported by the install server's NIOSSL context (SSLKEYLOGFILE format),
/// kept in memory only to decrypt handshake records of TLS 1.3 connections.
final class TLSKeyLogStore {
	static let shared = TLSKeyLogStore()

	private let _lock = NSLock()
	/// client random (hex) → label → secret
	private var _secrets: [String: [String: [UInt8]]] = [:]
	private var _order: [String] = []

	private init() {}

	func add(_ line: ByteBuffer) {
		let text = String(decoding: line.readableBytesView, as: UTF8.self)

		for rawLine in text.split(whereSeparator: \.isNewline) {
			let parts = rawLine.split(separator: " ")
			guard parts.count == 3, let secret = TLSConnectionSniffer.bytes(fromHex: parts[2]) else { continue }

			let label = String(parts[0])
			let random = parts[1].lowercased()

			_lock.lock()
			if _secrets[random] == nil {
				_order.append(random)
				if _order.count > 32 {
					_secrets[_order.removeFirst()] = nil
				}
			}
			_secrets[random, default: [:]][label] = secret
			_lock.unlock()
		}
	}

	func secret(_ label: String, clientRandom: String) -> [UInt8]? {
		_lock.lock()
		defer { _lock.unlock() }
		return _secrets[clientRandom]?[label]
	}

	func remove(clientRandom: String) {
		_lock.lock()
		_secrets[clientRandom] = nil
		_order.removeAll { $0 == clientRandom }
		_lock.unlock()
	}

	func removeAll() {
		_lock.lock()
		_secrets.removeAll()
		_order.removeAll()
		_lock.unlock()
	}
}

// MARK: - TLS sniffer
/// Passive TLS record parser for one connection (both directions), event loop confined.
final class TLSConnectionSniffer {
	enum Direction: Hashable {
		case client
		case server

		var name: String { self == .client ? "client" : "server" }
		var secretPrefix: String { self == .client ? "CLIENT" : "SERVER" }
	}

	private enum KeyPhase {
		case plaintext
		case handshake
		case application
	}

	private struct DirectionState {
		var pending: [UInt8] = []
		var inspectedBytes = 0
		var done = false
		var sawRecord = false
		var handshakeBuffer: [UInt8] = []
		var phase: KeyPhase = .plaintext
		var sequence: UInt64 = 0
		var key: [UInt8]?
		var iv: [UInt8]?
		var undecryptedRecords = 0
	}

	private static let _inspectLimit = 64 * 1024
	private static let _helloRetryRandom: [UInt8] = [
		0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
		0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C
	]

	private let _id: Int
	private var _client = DirectionState()
	private var _server = DirectionState()

	private var _clientRandom: String?
	private var _cipher: UInt16?
	private var _isTLS13 = false
	private var _nonTLS = false

	private var _sawClientHello = false
	private var _sawServerHello = false
	private var _sawServerCertificate = false
	private var _clientAccepted = false
	private var _clientAppData = false
	private var _clientAlert: String?
	private var _serverAlert: String?

	init(id: Int) {
		_id = id
	}

	private func _log(_ message: String) {
		InstallServerLog.shared.add("#\(_id) \(message)")
	}

	// MARK: Summary

	var verdict: String {
		if _nonTLS {
			return "not TLS (plain data sent to the HTTPS port)"
		}
		if !_sawClientHello {
			return "client never sent a TLS ClientHello"
		}
		if let alert = _serverAlert, !_clientAccepted {
			return "server aborted the handshake: \(alert)"
		}
		if !_sawServerHello {
			return "server did not answer the ClientHello"
		}
		if let alert = _clientAlert, !_clientAccepted {
			return "client REJECTED the handshake with alert \(alert)"
		}
		if !_clientAccepted {
			return _sawServerCertificate
				? "client closed after receiving the server certificate, without an alert (likely did not trust it)"
				: "client closed during the handshake, without an alert"
		}
		if !_clientAppData {
			return "TLS handshake OK, but the client sent no request"
		}
		return "TLS handshake OK, request sent"
	}

	func finish() {
		if let random = _clientRandom {
			TLSKeyLogStore.shared.remove(clientRandom: random)
		}
	}

	// MARK: Records

	func feed(_ buffer: ByteBuffer, from side: Direction) {
		var state = _state(side)
		guard !state.done else { return }

		let room = Self._inspectLimit - state.inspectedBytes
		let bytes = Array(buffer.readableBytesView.prefix(max(0, room)))
		state.inspectedBytes += bytes.count
		state.pending += bytes
		_setState(side, state)

		while true {
			state = _state(side)
			guard !state.done, state.pending.count >= 5 else { break }

			let type = state.pending[0]
			let length = Int(state.pending[3]) << 8 | Int(state.pending[4])

			if !state.sawRecord && !(20...23).contains(type) {
				_nonTLS = true
				_log("\(side.name) sent non-TLS data: \"\(Self._printable(state.pending, limit: 80))\"")
				state.done = true
				_setState(side, state)
				break
			}
			if length > 18432 {
				_log("\(side.name) sent a malformed TLS record (\(length) bytes), stopped inspecting")
				state.done = true
				_setState(side, state)
				break
			}
			guard state.pending.count >= 5 + length else { break }

			let header = Array(state.pending[0..<5])
			let body = Array(state.pending[5..<(5 + length)])
			state.pending.removeFirst(5 + length)
			state.sawRecord = true
			_setState(side, state)

			_record(type: type, header: header, body: body, from: side)
		}

		state = _state(side)
		if !state.done && state.inspectedBytes >= Self._inspectLimit {
			state.done = true
			state.pending.removeAll()
			_setState(side, state)
		}
	}

	private func _state(_ side: Direction) -> DirectionState {
		side == .client ? _client : _server
	}

	private func _setState(_ side: Direction, _ state: DirectionState) {
		if side == .client {
			_client = state
		} else {
			_server = state
		}
	}

	private func _markDone(_ side: Direction) {
		var state = _state(side)
		state.done = true
		state.pending.removeAll()
		_setState(side, state)
	}

	private func _record(type: UInt8, header: [UInt8], body: [UInt8], from side: Direction) {
		let state = _state(side)

		switch type {
		case 22 where state.phase == .plaintext:
			_appendHandshake(body, from: side, encrypted: false)
		case 21:
			_alert(body, from: side, encrypted: false)
		case 20:
			if !_isTLS13 {
				_log("\(side.name) ChangeCipherSpec (TLS 1.2), further records are encrypted")
				if side == .client {
					_clientAccepted = true
				}
				_markDone(side)
			}
		case 23 where _isTLS13 && state.phase != .plaintext:
			_decrypt(header: header, body: body, from: side)
		case 23:
			_log("\(side.name) application data record (\(body.count) B)")
			if side == .client, _clientAccepted {
				_clientAppData = true
			}
			_markDone(side)
		default:
			_log("\(side.name) TLS record type \(type) (\(body.count) B)")
		}
	}

	// MARK: Handshake

	private func _appendHandshake(_ data: [UInt8], from side: Direction, encrypted: Bool) {
		var state = _state(side)
		state.handshakeBuffer += data
		_setState(side, state)

		while true {
			state = _state(side)
			let buffer = state.handshakeBuffer
			guard buffer.count >= 4 else { break }

			let length = Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
			guard buffer.count >= 4 + length else { break }

			let message = Array(buffer[4..<(4 + length)])
			state.handshakeBuffer.removeFirst(4 + length)
			_setState(side, state)

			_handshake(type: buffer[0], body: message, from: side, encrypted: encrypted)
		}
	}

	private func _handshake(type: UInt8, body: [UInt8], from side: Direction, encrypted: Bool) {
		switch type {
		case 1:
			_clientHello(body)
		case 2:
			_serverHello(body)
		case 4:
			break // NewSessionTicket
		case 8:
			_encryptedExtensions(body)
		case 11:
			_certificate(body, from: side)
		case 13:
			_log("\(side.name) CertificateRequest")
		case 14:
			_log("server ServerHelloDone")
		case 15:
			_log("\(side.name) CertificateVerify")
		case 16:
			_log("client ClientKeyExchange (TLS 1.2: client accepted the server certificate)")
			_clientAccepted = true
		case 20:
			_log("\(side.name) Finished" + (side == .client ? " (client ACCEPTED the server certificate)" : ""))
			if side == .client {
				_clientAccepted = true
			}
			if encrypted {
				var state = _state(side)
				state.phase = .application
				state.sequence = 0
				state.key = nil
				state.iv = nil
				state.handshakeBuffer.removeAll()
				_setState(side, state)
			}
		default:
			_log("\(side.name) handshake message type \(type) (\(body.count) B)")
		}
	}

	private func _clientHello(_ body: [UInt8]) {
		var reader = ByteReader(body)
		guard
			let legacyVersion = reader.u16(),
			let random = reader.bytes(32),
			let sessionLength = reader.u8(), reader.skip(Int(sessionLength)),
			let ciphersLength = reader.u16(), let ciphers = reader.bytes(Int(ciphersLength)),
			let compressionLength = reader.u8(), reader.skip(Int(compressionLength))
		else {
			_log("client ClientHello (unparsable, \(body.count) B)")
			return
		}

		_sawClientHello = true
		_clientRandom = Self._hex(random)

		var sni = "none"
		var alpn: [String] = []
		var versions: [String] = []
		var groups: [String] = []

		for (type, data) in Self._extensions(&reader) {
			var ext = ByteReader(data)
			switch type {
			case 0:
				_ = ext.u16()
				if ext.u8() == 0, let length = ext.u16(), let name = ext.bytes(Int(length)) {
					sni = String(decoding: name, as: UTF8.self)
				}
			case 16:
				alpn = Self._alpnList(&ext)
			case 43:
				if let length = ext.u8() {
					for _ in 0..<(Int(length) / 2) {
						if let version = ext.u16() { versions.append(Self._versionName(version)) }
					}
				}
			case 10:
				if let length = ext.u16() {
					for _ in 0..<(Int(length) / 2) {
						if let group = ext.u16() { groups.append(Self._groupName(group)) }
					}
				}
			default:
				break
			}
		}

		var cipherNames: [String] = []
		var cipherReader = ByteReader(ciphers)
		while let cipher = cipherReader.u16() {
			cipherNames.append(Self._cipherName(cipher))
		}

		_log(
			"client ClientHello: legacy \(Self._versionName(legacyVersion)), "
			+ "versions [\(versions.joined(separator: ", "))], SNI \(sni), "
			+ "ALPN [\(alpn.joined(separator: ", "))], groups [\(groups.joined(separator: ", "))], "
			+ "\(cipherNames.count) ciphers [\(cipherNames.prefix(8).joined(separator: ", "))]"
		)
	}

	private func _serverHello(_ body: [UInt8]) {
		var reader = ByteReader(body)
		guard
			let legacyVersion = reader.u16(),
			let random = reader.bytes(32),
			let sessionLength = reader.u8(), reader.skip(Int(sessionLength)),
			let cipher = reader.u16(),
			reader.skip(1)
		else {
			_log("server ServerHello (unparsable, \(body.count) B)")
			return
		}

		var version = legacyVersion
		var alpn: [String] = []
		for (type, data) in Self._extensions(&reader) {
			var ext = ByteReader(data)
			switch type {
			case 43:
				if let selected = ext.u16() { version = selected }
			case 16:
				alpn = Self._alpnList(&ext)
			default:
				break
			}
		}

		if random == Self._helloRetryRandom {
			_log("server HelloRetryRequest (\(Self._cipherName(cipher)))")
			return
		}

		_sawServerHello = true
		_cipher = cipher
		_isTLS13 = version == 0x0304

		_log(
			"server ServerHello: \(Self._versionName(version)), \(Self._cipherName(cipher))"
			+ (alpn.isEmpty ? "" : ", ALPN \(alpn.joined(separator: ", "))")
		)

		if _isTLS13 {
			for side in [Direction.client, .server] {
				var state = _state(side)
				state.phase = .handshake
				state.sequence = 0
				state.handshakeBuffer.removeAll()
				_setState(side, state)
			}
		}
	}

	private func _encryptedExtensions(_ body: [UInt8]) {
		var reader = ByteReader(body)
		var alpn = "none"
		for (type, data) in Self._extensions(&reader) where type == 16 {
			var ext = ByteReader(data)
			alpn = Self._alpnList(&ext).joined(separator: ", ")
		}
		_log("server EncryptedExtensions: ALPN \(alpn)")
	}

	private func _certificate(_ body: [UInt8], from side: Direction) {
		var reader = ByteReader(body)
		if _isTLS13, let contextLength = reader.u8() {
			_ = reader.skip(Int(contextLength))
		}
		guard let listLength = reader.u24(), var list = reader.bytes(Int(listLength)).map({ ByteReader($0) }) else {
			_log("\(side.name) Certificate (unparsable)")
			return
		}

		var sizes: [Int] = []
		while let length = list.u24(), list.skip(Int(length)) {
			sizes.append(Int(length))
			if _isTLS13, let extLength = list.u16() {
				_ = list.skip(Int(extLength))
			}
		}

		if side == .server {
			_sawServerCertificate = true
		}
		_log("\(side.name) Certificate: \(sizes.count) certificate(s), sizes \(sizes.map { String($0) }.joined(separator: "/")) B")
	}

	// MARK: Alerts

	private func _alert(_ body: [UInt8], from side: Direction, encrypted: Bool) {
		guard body.count >= 2 else { return }

		let level = body[0] == 2 ? "fatal" : (body[0] == 1 ? "warning" : "level \(body[0])")
		let description = "\(Self._alertName(body[1]))(\(body[1]))"
		_log("\(side.name) sent alert\(encrypted ? " (encrypted)" : ""): \(level) \(description)")

		if body[1] != 0 {
			if side == .client {
				_clientAlert = _clientAlert ?? description
			} else {
				_serverAlert = _serverAlert ?? description
			}
		}
		if body[0] == 2 || body[1] == 0 {
			_markDone(side)
		}
	}

	// MARK: Decryption (TLS 1.3)

	private func _decrypt(header: [UInt8], body: [UInt8], from side: Direction) {
		var state = _state(side)

		if state.key == nil {
			let label = side.secretPrefix + (state.phase == .handshake ? "_HANDSHAKE_TRAFFIC_SECRET" : "_TRAFFIC_SECRET_0")
			guard
				let cipher = _cipher,
				let random = _clientRandom,
				let secret = TLSKeyLogStore.shared.secret(label, clientRandom: random),
				let keys = Self._trafficKeys(cipher: cipher, secret: secret)
			else {
				state.undecryptedRecords += 1
				_setState(side, state)
				_log(
					"\(side.name) encrypted record (\(body.count) B, no key)"
					+ (body.count == 19 ? ", size of an encrypted alert" : "")
				)
				if state.undecryptedRecords >= 4 {
					_markDone(side)
				}
				return
			}
			state.key = keys.key
			state.iv = keys.iv
		}

		guard
			let cipher = _cipher, let key = state.key, let iv = state.iv,
			let plaintext = Self._open(cipher: cipher, key: key, iv: iv, sequence: state.sequence, header: header, body: body)
		else {
			_log("\(side.name) encrypted record (\(body.count) B) could not be decrypted, stopped inspecting")
			_markDone(side)
			return
		}

		state.sequence += 1
		_setState(side, state)

		guard let typeIndex = plaintext.lastIndex(where: { $0 != 0 }) else { return }
		let innerType = plaintext[typeIndex]
		let content = Array(plaintext[..<typeIndex])

		switch innerType {
		case 21:
			_alert(content, from: side, encrypted: true)
		case 22:
			if state.phase == .handshake {
				_appendHandshake(content, from: side, encrypted: true)
			} else if let first = content.first, first != 4 {
				_log("\(side.name) post-handshake message type \(first)")
			}
		case 23:
			if side == .client {
				_clientAppData = true
			}
			let preface = Array("PRI * HTTP/2.0".utf8)
			if content.starts(with: preface) {
				_log("\(side.name) application data: HTTP/2 connection preface (\(content.count) B)")
			} else {
				_log("\(side.name) application data: \"\(Self._printable(content, limit: 80))\" (\(content.count) B)")
			}
			_markDone(side)
		default:
			_log("\(side.name) encrypted record with inner type \(innerType)")
		}
	}

	private static func _trafficKeys(cipher: UInt16, secret: [UInt8]) -> (key: [UInt8], iv: [UInt8])? {
		switch cipher {
		case 0x1301:
			return (_expandLabel(SHA256.self, secret: secret, label: "key", length: 16),
					_expandLabel(SHA256.self, secret: secret, label: "iv", length: 12))
		case 0x1302:
			return (_expandLabel(SHA384.self, secret: secret, label: "key", length: 32),
					_expandLabel(SHA384.self, secret: secret, label: "iv", length: 12))
		case 0x1303:
			return (_expandLabel(SHA256.self, secret: secret, label: "key", length: 32),
					_expandLabel(SHA256.self, secret: secret, label: "iv", length: 12))
		default:
			return nil
		}
	}

	/// HKDF-Expand-Label (RFC 8446 §7.1) with an empty context.
	private static func _expandLabel<H: HashFunction>(_ hash: H.Type, secret: [UInt8], label: String, length: Int) -> [UInt8] {
		let fullLabel = Array("tls13 \(label)".utf8)
		var info: [UInt8] = [UInt8(length >> 8), UInt8(length & 0xFF), UInt8(fullLabel.count)]
		info += fullLabel
		info.append(0)

		let key = HKDF<H>.expand(pseudoRandomKey: SymmetricKey(data: secret), info: info, outputByteCount: length)
		return key.withUnsafeBytes { Array($0) }
	}

	private static func _open(cipher: UInt16, key: [UInt8], iv: [UInt8], sequence: UInt64, header: [UInt8], body: [UInt8]) -> [UInt8]? {
		guard body.count >= 17, iv.count == 12 else { return nil }

		var nonce = iv
		for i in 0..<8 {
			nonce[11 - i] ^= UInt8(truncatingIfNeeded: sequence >> (8 * UInt64(i)))
		}

		let ciphertext = Array(body[0..<(body.count - 16)])
		let tag = Array(body[(body.count - 16)...])
		let symmetricKey = SymmetricKey(data: key)

		do {
			switch cipher {
			case 0x1301, 0x1302:
				let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
				return Array(try AES.GCM.open(box, using: symmetricKey, authenticating: header))
			case 0x1303:
				let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
				return Array(try ChaChaPoly.open(box, using: symmetricKey, authenticating: header))
			default:
				return nil
			}
		} catch {
			return nil
		}
	}

	// MARK: Helpers

	private static func _extensions(_ reader: inout ByteReader) -> [(UInt16, [UInt8])] {
		guard let total = reader.u16(), let data = reader.bytes(Int(total)) else { return [] }
		var list = ByteReader(data)
		var result: [(UInt16, [UInt8])] = []
		while let type = list.u16(), let length = list.u16(), let value = list.bytes(Int(length)) {
			result.append((type, value))
		}
		return result
	}

	private static func _alpnList(_ reader: inout ByteReader) -> [String] {
		guard let total = reader.u16(), let data = reader.bytes(Int(total)) else { return [] }
		var list = ByteReader(data)
		var result: [String] = []
		while let length = list.u8(), let name = list.bytes(Int(length)) {
			result.append(String(decoding: name, as: UTF8.self))
		}
		return result
	}

	static func bytes<S: StringProtocol>(fromHex hex: S) -> [UInt8]? {
		let chars = Array(hex.utf8)
		guard chars.count % 2 == 0 else { return nil }

		func value(_ c: UInt8) -> UInt8? {
			switch c {
			case 48...57: return c - 48
			case 65...70: return c - 55
			case 97...102: return c - 87
			default: return nil
			}
		}

		var result: [UInt8] = []
		result.reserveCapacity(chars.count / 2)
		var index = 0
		while index < chars.count {
			guard let high = value(chars[index]), let low = value(chars[index + 1]) else { return nil }
			result.append(high << 4 | low)
			index += 2
		}
		return result
	}

	private static func _hex(_ bytes: [UInt8]) -> String {
		bytes.map { String(format: "%02x", $0) }.joined()
	}

	private static func _printable(_ bytes: [UInt8], limit: Int) -> String {
		String(bytes.prefix(limit).map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
	}

	private static func _versionName(_ version: UInt16) -> String {
		switch version {
		case 0x0304: return "TLS 1.3"
		case 0x0303: return "TLS 1.2"
		case 0x0302: return "TLS 1.1"
		case 0x0301: return "TLS 1.0"
		default: return String(format: "0x%04x", version)
		}
	}

	private static func _cipherName(_ cipher: UInt16) -> String {
		switch cipher {
		case 0x1301: return "TLS_AES_128_GCM_SHA256"
		case 0x1302: return "TLS_AES_256_GCM_SHA384"
		case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256"
		case 0xC02B: return "ECDHE_ECDSA_AES_128_GCM"
		case 0xC02C: return "ECDHE_ECDSA_AES_256_GCM"
		case 0xCCA9: return "ECDHE_ECDSA_CHACHA20"
		case 0xC02F: return "ECDHE_RSA_AES_128_GCM"
		case 0xC030: return "ECDHE_RSA_AES_256_GCM"
		case 0xCCA8: return "ECDHE_RSA_CHACHA20"
		default: return String(format: "0x%04x", cipher)
		}
	}

	private static func _groupName(_ group: UInt16) -> String {
		switch group {
		case 0x001D: return "x25519"
		case 0x0017: return "P-256"
		case 0x0018: return "P-384"
		case 0x0019: return "P-521"
		case 0x11EC: return "X25519MLKEM768"
		default: return String(format: "0x%04x", group)
		}
	}

	private static func _alertName(_ code: UInt8) -> String {
		switch code {
		case 0: return "close_notify"
		case 10: return "unexpected_message"
		case 20: return "bad_record_mac"
		case 22: return "record_overflow"
		case 40: return "handshake_failure"
		case 42: return "bad_certificate"
		case 43: return "unsupported_certificate"
		case 44: return "certificate_revoked"
		case 45: return "certificate_expired"
		case 46: return "certificate_unknown"
		case 47: return "illegal_parameter"
		case 48: return "unknown_ca"
		case 49: return "access_denied"
		case 50: return "decode_error"
		case 51: return "decrypt_error"
		case 70: return "protocol_version"
		case 71: return "insufficient_security"
		case 80: return "internal_error"
		case 86: return "inappropriate_fallback"
		case 90: return "user_canceled"
		case 109: return "missing_extension"
		case 110: return "unsupported_extension"
		case 112: return "unrecognized_name"
		case 116: return "certificate_required"
		case 120: return "no_application_protocol"
		default: return "alert"
		}
	}
}

// MARK: - Byte reader
private struct ByteReader {
	private let _bytes: [UInt8]
	private var _offset = 0

	init(_ bytes: [UInt8]) {
		_bytes = bytes
	}

	mutating func u8() -> UInt8? {
		guard _offset + 1 <= _bytes.count else { return nil }
		defer { _offset += 1 }
		return _bytes[_offset]
	}

	mutating func u16() -> UInt16? {
		guard _offset + 2 <= _bytes.count else { return nil }
		defer { _offset += 2 }
		return UInt16(_bytes[_offset]) << 8 | UInt16(_bytes[_offset + 1])
	}

	mutating func u24() -> Int? {
		guard _offset + 3 <= _bytes.count else { return nil }
		defer { _offset += 3 }
		return Int(_bytes[_offset]) << 16 | Int(_bytes[_offset + 1]) << 8 | Int(_bytes[_offset + 2])
	}

	mutating func bytes(_ count: Int) -> [UInt8]? {
		guard count >= 0, _offset + count <= _bytes.count else { return nil }
		defer { _offset += count }
		return Array(_bytes[_offset..<(_offset + count)])
	}

	mutating func skip(_ count: Int) -> Bool {
		guard count >= 0, _offset + count <= _bytes.count else { return false }
		_offset += count
		return true
	}
}
