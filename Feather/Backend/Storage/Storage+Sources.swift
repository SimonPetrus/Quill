//
//  Storage+Sources.swift
//  Feather
//
//  Created by samara on 12.04.2025.
//

import CoreData
import AltSourceKit
import OSLog
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Sources
extension Storage {
	/// Retrieve sources in an array, we don't normally need this in swiftUI but we have it for the copy sources action
	func getSources() -> [AltSource] {
		let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		return (try? context.fetch(request)) ?? []
	}
	
	func addSource(
		_ url: URL,
		name: String? = "Unknown",
		identifier: String,
		iconURL: URL? = nil,
		deferSave: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		if sourceExists(identifier) {
			completion(nil)
			Logger.misc.debug("ignoring \(identifier)")
			return
		}
		
		let generator = UIImpactFeedbackGenerator(style: .light)
		
		let new = AltSource(context: context)
		new.name = name
		new.date = Date()
		new.identifier = identifier
		new.sourceURL = url
		new.iconURL = iconURL
		
		do {
			if !deferSave {
				try context.save()
				generator.impactOccurred()
			}
			completion(nil)
		} catch {
			completion(error)
		}
	}
	
	func addSource(
		_ url: URL,
		repository: ASRepository,
		id: String = "",
		deferSave: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		addSource(
			url,
			name: repository.name,
			identifier: !id.isEmpty
				? id
				: (repository.id ?? url.absoluteString),
			iconURL: repository.currentIconURL,
			deferSave: deferSave,
			completion: completion
		)
	}

	func addSources(
		repos: [URL: ASRepository],
		completion: @escaping (Error?) -> Void
	) {
		let generator = UIImpactFeedbackGenerator(style: .light)
		
		for (url, repo) in repos {
			addSource(
				url,
				repository: repo,
				deferSave: true,
				completion: { error in
					if let error {
						completion(error)
					}
				}
			)
		}
		
		saveContext()
		generator.impactOccurred()
		completion(nil)
	}

	/// Adds the official Quill source once per installation (new and existing installs). A source the
	/// user deleted afterwards is not re-added because the flag stays set.
	func addOwnSourceIfNeeded() {
		let defaults = UserDefaults.standard
		guard !defaults.bool(forKey: SelfUpdateManager.didAddOwnSourceKey) else { return }
		defaults.set(true, forKey: SelfUpdateManager.didAddOwnSourceKey)
		guard let url = URL(string: SelfUpdateManager.defaultSourceURL) else { return }
		addSource(url, name: "Quill", identifier: SelfUpdateManager.ownSourceIdentifier) { _ in }
	}

	func deleteSource(for source: AltSource) {
		context.delete(source)
		saveContext()
	}

	/// Pin or unpin a source so it is listed in the pinned section of the sources list.
	func togglePin(for source: AltSource) {
		source.isPinned.toggle()
		saveContext()
	}

	func sourceExists(_ identifier: String) -> Bool {
		let fetchRequest: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		fetchRequest.predicate = NSPredicate(format: "identifier == %@", identifier)

		do {
			let count = try context.count(for: fetchRequest)
			return count > 0
		} catch {
			Logger.misc.error("Error checking if repository exists: \(error, privacy: .public)")
			return false
		}
	}
}
