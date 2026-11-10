//
//  LegacyMigration.swift
//  Quill
//
//  One-time migration from the storage names used before the app was renamed
//  (Core Data store, Application Support folder, UserDefaults keys, caches).
//  The old name is assembled at runtime on purpose, so it does not appear as a
//  literal in the shipped binary.
//

import Foundation
import UIKit
import OSLog

enum LegacyMigration {
	private static let _doneKey = "Quill.didMigrateLegacy"
	private static let _lock = NSLock()
	private static var _didRun = false

	/// Old product name, decoded at runtime from shifted bytes. `k` is 0 in practice but opaque to the
	/// compiler, so the optimizer cannot fold the result back into a plain string literal.
	static var legacyName: String {
		let k = UInt8(truncatingIfNeeded: ProcessInfo.processInfo.arguments.count / 4096)
		return String(decoding: [71, 102, 98, 117, 105, 102, 115].map { $0 &- 1 &+ k }, as: UTF8.self)
	}

	private static var _supportDir: URL { URL.applicationSupportDirectory }
	private static var _oldStore: URL { _supportDir.appendingPathComponent("\(legacyName).sqlite") }

	/// True while the migration has not completed (flag missing) or an old-named store is still on disk.
	/// While true, the destructive "reset on load failure" path must not run.
	static var isPending: Bool {
		!UserDefaults.standard.bool(forKey: _doneKey) || FileManager.default.fileExists(atPath: _oldStore.path)
	}

	/// Runs the migration once per launch, before any storage is loaded. Safe to call repeatedly.
	static func runIfNeeded() {
		_lock.lock()
		defer { _lock.unlock() }
		guard !_didRun else { return }
		_didRun = true

		let defaults = UserDefaults.standard
		guard !defaults.bool(forKey: _doneKey) else { return }

		let storeOK = _migrateStore()
		let supportOK = _migrateApplicationSupport()
		_migrateDefaults(defaults)
		_removeLegacyCache()

		// The flag is written only after everything succeeded, otherwise the next launch retries.
		if storeOK && supportOK {
			defaults.set(true, forKey: _doneKey)
		} else {
			Logger.misc.error("Legacy migration incomplete, will retry on next launch")
		}
	}

	/// Alternate icons no longer exist: go back to the primary icon. Call after launch (main thread).
	static func resetAlternateIcon() {
		DispatchQueue.main.async {
			guard UIApplication.shared.alternateIconName != nil else { return }
			UIApplication.shared.setAlternateIconName(nil) { error in
				if let error {
					Logger.misc.error("Resetting alternate icon failed: \(error.localizedDescription)")
				}
			}
		}
	}

	// MARK: Core Data store

	/// Moves `<old>.sqlite` (+ -wal / -shm) to `Quill.sqlite…`. Order: -wal, -shm, then the main file last
	/// (the main file is the commit marker). Any failure rolls back what was already moved.
	/// Returns true when no old main store remains afterwards.
	private static func _migrateStore() -> Bool {
		let fm = FileManager.default
		let dir = _supportDir
		let old = legacyName
		func url(_ name: String, _ suffix: String) -> URL { dir.appendingPathComponent("\(name).sqlite\(suffix)") }

		let oldMain = url(old, "")
		let newMain = url("Quill", "")
		let oldExists = fm.fileExists(atPath: oldMain.path)

		if fm.fileExists(atPath: newMain.path) {
			if oldExists {
				Logger.misc.error("Legacy store and new store both exist, leaving the legacy store untouched")
			}
			return !oldExists
		}

		// A previous attempt may have left -wal/-shm behind under the new name without the main file.
		for suffix in ["-wal", "-shm"] {
			let orphan = url("Quill", suffix)
			guard fm.fileExists(atPath: orphan.path) else { continue }
			let back = url(old, suffix)
			do {
				if oldExists && !fm.fileExists(atPath: back.path) {
					try fm.moveItem(at: orphan, to: back)
				} else {
					try fm.removeItem(at: orphan)
				}
			} catch {
				Logger.misc.error("Could not clean up partial store migration: \(error.localizedDescription)")
				return false
			}
		}

		guard oldExists else { return true } // nothing to migrate

		var moved: [String] = []
		func rollback() {
			for suffix in moved {
				try? fm.moveItem(at: url("Quill", suffix), to: url(old, suffix))
			}
		}

		for suffix in ["-wal", "-shm", ""] {
			let source = url(old, suffix)
			guard fm.fileExists(atPath: source.path) else { continue }
			do {
				try fm.moveItem(at: source, to: url("Quill", suffix))
				moved.append(suffix)
			} catch {
				Logger.misc.error("Store migration failed for \(suffix.isEmpty ? "main" : suffix): \(error.localizedDescription)")
				rollback()
				return false
			}
		}
		return !fm.fileExists(atPath: oldMain.path)
	}

	// MARK: Application Support folder (LocalCA etc.)

	/// Returns true when the old folder is gone afterwards. It is only removed once completely empty.
	private static func _migrateApplicationSupport() -> Bool {
		let fm = FileManager.default
		let oldDir = _supportDir.appendingPathComponent(legacyName, isDirectory: true)
		let newDir = _supportDir.appendingPathComponent("Quill", isDirectory: true)

		guard fm.fileExists(atPath: oldDir.path) else { return true }

		if !fm.fileExists(atPath: newDir.path) {
			do {
				try fm.moveItem(at: oldDir, to: newDir)
				return true
			} catch {
				Logger.misc.error("Application Support migration failed: \(error.localizedDescription)")
				return false
			}
		}

		// New folder already exists: move children that are missing there, keep conflicting ones.
		if let children = try? fm.contentsOfDirectory(atPath: oldDir.path) {
			for child in children {
				let target = newDir.appendingPathComponent(child)
				guard !fm.fileExists(atPath: target.path) else { continue }
				do {
					try fm.moveItem(at: oldDir.appendingPathComponent(child), to: target)
				} catch {
					Logger.misc.error("Could not move \(child): \(error.localizedDescription)")
				}
			}
		}

		if (try? fm.contentsOfDirectory(atPath: oldDir.path))?.isEmpty == true {
			try? fm.removeItem(at: oldDir)
		}
		return !fm.fileExists(atPath: oldDir.path)
	}

	// MARK: UserDefaults

	/// `<old>.xxx` / `<lowercase old>.xxx` -> `Quill.xxx` (value is copied unless the new key already has one, old key is removed).
	private static func _migrateDefaults(_ defaults: UserDefaults) {
		let old = legacyName
		let prefixes = ["\(old).", "\(old.lowercased())."]

		for (key, value) in defaults.dictionaryRepresentation() {
			guard let prefix = prefixes.first(where: { key.hasPrefix($0) }) else { continue }
			let newKey = "Quill." + key.dropFirst(prefix.count)
			if defaults.object(forKey: newKey) == nil {
				defaults.set(value, forKey: newKey)
			}
			defaults.removeObject(forKey: key)
		}
	}

	// MARK: Caches

	/// Old Nuke disk cache (a cache, not data).
	private static func _removeLegacyCache() {
		let cache = URL.cachesDirectory.appendingPathComponent("thewonderofyou.\(legacyName).datacache", isDirectory: true)
		if FileManager.default.fileExists(atPath: cache.path) {
			try? FileManager.default.removeItem(at: cache)
		}
	}
}
