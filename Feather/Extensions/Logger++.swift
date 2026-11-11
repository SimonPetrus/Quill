//
//  Logger++.swift
//  Feather
//
//  Created by samara on 24.05.2025.
//

import OSLog

extension Logger {
	private static var subsystem = Bundle.main.bundleIdentifier!
	static let signing = Logger(subsystem: subsystem, category: "Signing")
	static let misc = Logger(subsystem: subsystem, category: "Misc")
	/// URLs handed to the app ("Open in", share sheet, quill:// links) and their import.
	static let incoming = Logger(subsystem: subsystem, category: "IncomingURL")
}
