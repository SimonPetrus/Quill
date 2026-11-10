//
//  LogExporter.swift
//  Quill
//
//  Exports the app's own os_log entries (last 24 hours) to a .txt file for the share sheet.
//

import Foundation
import OSLog

enum LogExporter {
	enum ExportError: LocalizedError {
		case unavailable
		var errorDescription: String? { .localized("Logs could not be read.") }
	}
	
	/// Reads entries of this process whose subsystem is the app's bundle identifier and writes them to a file.
	/// Note: `.currentProcessIdentifier` only covers the current run of the app.
	static func export() async throws -> URL {
		try await Task.detached(priority: .userInitiated) {
			let subsystem = Bundle.main.bundleIdentifier ?? "Quill"
			let store = try OSLogStore(scope: .currentProcessIdentifier)
			let start = store.position(date: Date().addingTimeInterval(-24 * 60 * 60))
			let entries = try store.getEntries(at: start, matching: NSPredicate(format: "subsystem == %@", subsystem))
			
			let formatter = ISO8601DateFormatter()
			var lines: [String] = [
				"Quill logs (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"))",
				"Exported: \(formatter.string(from: Date())) | Window: last 24 hours, current app run",
				""
			]
			for case let entry as OSLogEntryLog in entries {
				lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(_level(entry.level)): \(entry.composedMessage)")
			}
			
			let url = FileManager.default.temporaryDirectory.appendingPathComponent("Quill-Logs.txt")
			try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
			return url
		}.value
	}
	
	private static func _level(_ level: OSLogEntryLog.Level) -> String {
		switch level {
		case .debug: "DEBUG"
		case .info: "INFO"
		case .notice: "NOTICE"
		case .error: "ERROR"
		case .fault: "FAULT"
		default: "LOG"
		}
	}
}
