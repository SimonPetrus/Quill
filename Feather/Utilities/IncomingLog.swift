//
//  IncomingLog.swift
//  Quill
//
//  Diagnostics for URLs / files handed to the app ("Open in", share sheet, quill:// links).
//

import Foundation
import OSLog

/// Writes to `Logger.incoming` and to a small persistent file, so "Export Logs" also shows earlier
/// runs (`OSLogStore` on iOS only covers the current process). Callers must pass only public-safe
/// text: scheme, extension, kind of source, stage, type identifiers, counts and error codes —
/// never file paths, file names or query strings.
enum IncomingLog {
	/// The file is trimmed to its newest half once it grows beyond this size.
	private static let _maxBytes = 256 * 1024
	private static let _queue = DispatchQueue(label: "Quill.IncomingLog", qos: .utility)
	private static let _formatter = ISO8601DateFormatter()

	/// Application Support (not visible in Files, unlike Documents).
	static var fileURL: URL {
		URL.applicationSupportDirectory
			.appendingPathComponent("Quill", isDirectory: true)
			.appendingPathComponent("Logs", isDirectory: true)
			.appendingPathComponent("incoming.log")
	}

	static func notice(_ message: String) {
		Logger.incoming.notice("\(message, privacy: .public)")
		_append("NOTICE", message)
	}

	static func error(_ message: String) {
		Logger.incoming.error("\(message, privacy: .public)")
		_append("ERROR", message)
	}

	/// Marks the start of a new app run in the persistent file.
	static func startRun() {
		let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
		notice("App run started: version=\(version)")
	}

	/// Contents of the persistent file (all runs, newest last), or nil if there is none.
	static func history() -> String? {
		_queue.sync {
			try? String(contentsOf: fileURL, encoding: .utf8)
		}
	}

	/// Deletes the persistent file (Reset All).
	static func clear() {
		_queue.async {
			try? FileManager.default.removeItem(at: fileURL)
		}
	}

	private static func _append(_ level: String, _ message: String) {
		let line = "\(_formatter.string(from: Date())) [IncomingURL] \(level): \(message)\n"
		_queue.async {
			let fileManager = FileManager.default
			let url = fileURL
			do {
				try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				if !fileManager.fileExists(atPath: url.path) {
					fileManager.createFile(atPath: url.path, contents: nil)
				}
				let handle = try FileHandle(forWritingTo: url)
				defer { try? handle.close() }
				let end = try handle.seekToEnd()
				try handle.write(contentsOf: Data(line.utf8))
				if end + UInt64(line.utf8.count) > UInt64(_maxBytes) {
					try? handle.close()
					_trim(url)
				}
			} catch {
				// Diagnostics only: never fail the caller.
			}
		}
	}

	/// Keeps the newest half of the file, cut at a line boundary.
	private static func _trim(_ url: URL) {
		guard let data = try? Data(contentsOf: url), data.count > _maxBytes / 2 else { return }
		var tail = data.suffix(_maxBytes / 2)
		if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
			tail = tail[tail.index(after: newline)...]
		}
		try? Data(tail).write(to: url, options: .atomic)
	}
}
