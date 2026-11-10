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

	/// True while an old-named main store is still on disk (migration did not complete).
	/// While true, the destructive "reset on load failure" path must not run.
	static var isPending: Bool {
		FileManager.default.fileExists(atPath: _oldStore.path)
	}

	/// Store file the app must open this session: the old file if it could not be moved
	/// (so no empty new store is created and no data is hidden), otherwise nil (= default `Quill.sqlite`).
	static var fallbackStoreURL: URL? {
		isPending ? _oldStore : nil
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
		_migrateApplicationSupport()
		_migrateDefaults(defaults)
		_removeLegacyCache()

		// The flag is written only after the store migration succeeded, otherwise the next launch retries.
		if storeOK {
			defaults.set(true, forKey: _doneKey)
		} else {
			Logger.misc.error("Legacy store migration incomplete, will retry on next launch")
		}
	}

	private static var _iconObserver: NSObjectProtocol?

	/// Alternate icons no longer exist: go back to the primary icon once the app is active
	/// (the call can be rejected during launch). Retries on the next activation until it succeeds.
	static func resetAlternateIcon() {
		DispatchQueue.main.async {
			guard UIApplication.shared.alternateIconName != nil, _iconObserver == nil else { return }
			_iconObserver = NotificationCenter.default.addObserver(
				forName: UIApplication.didBecomeActiveNotification,
				object: nil,
				queue: .main
			) { _ in
				func finish() {
					if let token = _iconObserver { NotificationCenter.default.removeObserver(token) }
					_iconObserver = nil
				}
				guard UIApplication.shared.alternateIconName != nil else { return finish() }
				UIApplication.shared.setAlternateIconName(nil) { error in
					if let error {
						Logger.misc.error("Resetting alternate icon failed: \(error.localizedDescription)")
					} else {
						DispatchQueue.main.async { finish() }
					}
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
			guard oldExists else { return true }
			// Both exist (e.g. left by an earlier failed attempt). Only if the new store is clearly smaller
			// (an empty store Core Data created) it is set aside; otherwise the old one stays and is opened.
			func size(_ name: String) -> Int {
				["", "-wal", "-shm"].reduce(0) { sum, suffix in
					let attrs = try? fm.attributesOfItem(atPath: url(name, suffix).path)
					return sum + ((attrs?[.size] as? Int) ?? 0)
				}
			}
			guard size("Quill") < size(old) else {
				Logger.misc.error("Legacy and new store both exist, not sure which is current: opening the legacy store")
				return false
			}
			let stamp = Int(Date().timeIntervalSince1970)
			for suffix in ["", "-wal", "-shm"] {
				let source = url("Quill", suffix)
				guard fm.fileExists(atPath: source.path) else { continue }
				let target = dir.appendingPathComponent("Quill.sqlite\(suffix).orphan-\(stamp)")
				do {
					try fm.moveItem(at: source, to: target)
				} catch {
					Logger.misc.error("Could not set aside the empty new store: \(error.localizedDescription)")
					return false
				}
			}
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

	/// Moves the old folder over. Does not influence the migration flag or `isPending`.
	private static func _migrateApplicationSupport() {
		let fm = FileManager.default
		let oldDir = _supportDir.appendingPathComponent(legacyName, isDirectory: true)
		let newDir = _supportDir.appendingPathComponent("Quill", isDirectory: true)

		guard fm.fileExists(atPath: oldDir.path) else { return }

		if !fm.fileExists(atPath: newDir.path) {
			do {
				try fm.moveItem(at: oldDir, to: newDir)
			} catch {
				Logger.misc.error("Application Support migration failed: \(error.localizedDescription)")
			}
			return
		}

		// New folder already exists: move missing children. A conflicting LocalCA is dropped (it is
		// regenerated anyway), other conflicts are kept next to the new item as `<name>.legacy`.
		for child in (try? fm.contentsOfDirectory(atPath: oldDir.path)) ?? [] {
			let source = oldDir.appendingPathComponent(child)
			var target = newDir.appendingPathComponent(child)
			if fm.fileExists(atPath: target.path) {
				if child == "LocalCA" {
					try? fm.removeItem(at: source)
					continue
				}
				target = newDir.appendingPathComponent(child + ".legacy")
				guard !fm.fileExists(atPath: target.path) else { continue }
			}
			do {
				try fm.moveItem(at: source, to: target)
			} catch {
				Logger.misc.error("Could not move \(child): \(error.localizedDescription)")
			}
		}

		if (try? fm.contentsOfDirectory(atPath: oldDir.path))?.isEmpty == true {
			try? fm.removeItem(at: oldDir)
		}
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
