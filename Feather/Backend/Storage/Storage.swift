//
//  Persistence.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import CoreData
import Foundation
import OSLog

// MARK: - Storage
final class Storage: ObservableObject {
	static let shared = Storage()
	let container: NSPersistentContainer
	
	private let _name: String = "Quill"
	
	/// Set when the store had to be moved aside at launch; shown once by the app UI.
	static var startupNotice: String?

	init(inMemory: Bool = false) {
		LegacyMigration.runIfNeeded()
		container = NSPersistentContainer(name: _name)

		// If the old store could not be moved, keep using it for this session instead of creating an empty new one.
		if !inMemory, let legacy = LegacyMigration.fallbackStoreURL {
			container.persistentStoreDescriptions.first?.url = legacy
		}

		if inMemory {
			container.persistentStoreDescriptions.first?.url =
				URL(fileURLWithPath: "/dev/null")
		}
		
		container.persistentStoreDescriptions.first?.shouldMigrateStoreAutomatically = true
		container.persistentStoreDescriptions.first?.shouldInferMappingModelAutomatically = true

		_loadPersistentStoreAggressively()
		container.viewContext.automaticallyMergesChangesFromParent = true
		container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
	}

	var context: NSManagedObjectContext {
		container.viewContext
	}
	
	func saveContext() {
		DispatchQueue.main.async {
			if self.context.hasChanges {
				try? self.context.save()
			}
		}
	}
	
	func clearContext<T: NSManagedObject>(request: NSFetchRequest<T>) {
		let deleteRequest = NSBatchDeleteRequest(fetchRequest: (request as? NSFetchRequest<NSFetchRequestResult>)!)
		_ = try? context.execute(deleteRequest)
	}
	
	func countContent<T: NSManagedObject>(for type: T.Type) -> String {
		let request = T.fetchRequest()
		return "\((try? context.count(for: request)) ?? 0)"
	}

	private func _loadPersistentStoreAggressively() {
		container.loadPersistentStores { description, error in
			if let error, LegacyMigration.isPending {
				// Migration from the old store name is incomplete: never wipe user data here.
				Logger.misc.error("Store load failed while legacy migration is pending: \(error.localizedDescription)")
				self.container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
				self.container.loadPersistentStores { _, error in
					if let error {
						fatalError("Core Data unrecoverable: \(error)")
					}
				}
			} else if let error {
				// Never delete user data: move the unreadable store aside and start with an empty one.
				let code = (error as NSError).code
				let result = self._backupStore(at: description.url)
				var backup: String?
				switch result {
				case .backedUp(let name): backup = name
				case .nothingToBack: break
				case .failed:
					// Old files are still in place: never open a fresh store over them.
					Logger.misc.error("Store load failed (Cocoa code \(code)) and backup failed, using in-memory store: \(error.localizedDescription)")
					self.container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
					self.container.loadPersistentStores { _, error in
						if let error {
							fatalError("Core Data unrecoverable: \(error)")
						}
					}
					return
				}
				Logger.misc.error("Store load failed (Cocoa code \(code)), backup: \(backup ?? "none"): \(error.localizedDescription)")
				if let backup {
					Storage.startupNotice = String(format: .localized("The database could not be opened; the old data was backed up (%@)."), backup)
				}
				self.container.loadPersistentStores { _, error in
					if let error {
						Logger.misc.error("Fresh store failed to load, falling back to in-memory: \(error.localizedDescription)")
						self.container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
						self.container.loadPersistentStores { _, error in
							if let error {
								fatalError("Core Data unrecoverable: \(error)")
							}
						}
					}
				}
			}
		}
	}

	private enum _BackupResult {
		case backedUp(String)
		case nothingToBack
		case failed
	}
	
	/// Moves the store files next to the original as `<name>.bak-<unix time>.sqlite` (+ wal/shm).
	/// The main file moves first; if it fails nothing is moved. If a wal/shm move fails, earlier moves are
	/// rolled back, so the result is either a complete backup or the original files untouched.
	private func _backupStore(at url: URL?) -> _BackupResult {
		guard let url, url.path != "/dev/null" else { return .nothingToBack }
		
		let fm = FileManager.default
		let dir = url.deletingLastPathComponent()
		let name = url.deletingPathExtension().lastPathComponent
		let stamp = Int(Date().timeIntervalSince1970)
		
		let main = dir.appendingPathComponent("\(name).sqlite")
		guard fm.fileExists(atPath: main.path) else { return .nothingToBack }
		let mainTarget = dir.appendingPathComponent("\(name).bak-\(stamp).sqlite")
		do {
			try fm.moveItem(at: main, to: mainTarget)
		} catch {
			Logger.misc.error("Could not back up \(main.lastPathComponent): \(error.localizedDescription)")
			return .failed
		}
		
		var moved: [(from: URL, to: URL)] = [(main, mainTarget)]
		for ext in ["sqlite-wal", "sqlite-shm"] {
			let source = dir.appendingPathComponent("\(name).\(ext)")
			guard fm.fileExists(atPath: source.path) else { continue }
			let target = dir.appendingPathComponent("\(name).bak-\(stamp).\(ext)")
			do {
				try fm.moveItem(at: source, to: target)
				moved.append((source, target))
			} catch {
				Logger.misc.error("Could not back up \(source.lastPathComponent), rolling back: \(error.localizedDescription)")
				for item in moved.reversed() {
					try? fm.moveItem(at: item.to, to: item.from)
				}
				return .failed
			}
		}
		
		return .backedUp(mainTarget.lastPathComponent)
	}
}
