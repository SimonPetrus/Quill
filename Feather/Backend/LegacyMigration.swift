//
//  LegacyMigration.swift
//  Quill
//
//  One-time migration from the storage names used before the app was renamed
//  (Core Data store, Application Support folder, UserDefaults keys).
//  The old name is assembled at runtime on purpose, so it does not appear as a
//  literal in the shipped binary.
//

import Foundation

enum LegacyMigration {
	private static let _doneKey = "Quill.didMigrateLegacy"
	private static let _lock = NSLock()
	private static var _didRun = false

	/// Old product name, decoded at runtime.
	private static var _old: String {
		String(decoding: [70, 101, 97, 116, 104, 101, 114], as: UTF8.self)
	}

	/// Runs the migration once per launch, before any storage is loaded. Safe to call repeatedly.
	static func runIfNeeded() {
		_lock.lock()
		defer { _lock.unlock() }
		guard !_didRun else { return }
		_didRun = true

		let defaults = UserDefaults.standard
		guard !defaults.bool(forKey: _doneKey) else { return }

		_migrateStore()
		_migrateApplicationSupport()
		_migrateDefaults(defaults)

		defaults.set(true, forKey: _doneKey)
	}

	// MARK: Core Data store

	/// `<old>.sqlite` (+ -wal / -shm) -> `Quill.sqlite` in the same directory, only if the new store does not exist yet.
	private static func _migrateStore() {
		let fm = FileManager.default
		let dir = URL.applicationSupportDirectory

		let newMain = dir.appendingPathComponent("Quill.sqlite")
		guard !fm.fileExists(atPath: newMain.path) else { return }

		let oldMain = dir.appendingPathComponent("\(_old).sqlite")
		guard fm.fileExists(atPath: oldMain.path) else { return }

		for suffix in ["", "-wal", "-shm"] {
			let source = dir.appendingPathComponent("\(_old).sqlite\(suffix)")
			let target = dir.appendingPathComponent("Quill.sqlite\(suffix)")
			guard fm.fileExists(atPath: source.path) else { continue }
			try? fm.removeItem(at: target)
			try? fm.moveItem(at: source, to: target)
		}
	}

	// MARK: Application Support folder (LocalCA etc.)

	private static func _migrateApplicationSupport() {
		let fm = FileManager.default
		let dir = URL.applicationSupportDirectory

		let oldDir = dir.appendingPathComponent(_old, isDirectory: true)
		let newDir = dir.appendingPathComponent("Quill", isDirectory: true)

		guard fm.fileExists(atPath: oldDir.path) else { return }

		if !fm.fileExists(atPath: newDir.path) {
			try? fm.moveItem(at: oldDir, to: newDir)
			return
		}

		// New folder already exists (e.g. created by an early launch): move children that are missing there.
		if let children = try? fm.contentsOfDirectory(atPath: oldDir.path) {
			for child in children {
				let target = newDir.appendingPathComponent(child)
				if !fm.fileExists(atPath: target.path) {
					try? fm.moveItem(at: oldDir.appendingPathComponent(child), to: target)
				}
			}
		}
		try? fm.removeItem(at: oldDir)
	}

	// MARK: UserDefaults

	/// `<old>.xxx` / `<lowercase old>.xxx` -> `Quill.xxx` (value is copied unless the new key already has one, old key is removed).
	private static func _migrateDefaults(_ defaults: UserDefaults) {
		let prefixes = ["\(_old).", "\(_old.lowercased())."]

		for (key, value) in defaults.dictionaryRepresentation() {
			guard let prefix = prefixes.first(where: { key.hasPrefix($0) }) else { continue }
			let newKey = "Quill." + key.dropFirst(prefix.count)
			if defaults.object(forKey: newKey) == nil {
				defaults.set(value, forKey: newKey)
			}
			defaults.removeObject(forKey: key)
		}
	}
}
