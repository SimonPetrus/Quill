//
//  IncomingURLRouter.swift
//  Quill
//

import Foundation
import Combine
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Single entry point for every URL handed to the app: files from "Open in" / the share sheet
/// (Files, Telegram, Safari, ...) and `quill://` links.
///
/// URLs can arrive before any UI exists (cold launch: the scene's connection options) and the same
/// URL can arrive twice through different paths (scene delegate, SwiftUI `onOpenURL`, Inbox scan).
/// They are queued here, de-duplicated, and handed to the app only once it is ready (scene active
/// and root view on screen), so a progress item and any error alert can actually be shown.
///
/// Logging (`IncomingLog`): only the scheme, the extension, the kind of source, type identifiers,
/// counts and the stage; file paths, file names and query strings are never logged.
final class IncomingURLRouter: ObservableObject {
	static let shared = IncomingURLRouter()

	enum Origin: String {
		/// `UIScene.ConnectionOptions.urlContexts` (cold launch).
		case sceneConnect = "scene-connect"
		/// `UISceneDelegate.scene(_:openURLContexts:)` (app already running).
		case sceneOpen = "scene-open"
		/// SwiftUI `onOpenURL`.
		case onOpenURL = "onOpenURL"
		/// File found in the system Inbox folders without a URL delivery (see `IncomingInboxScanner`).
		case inboxScan = "inbox-scan"
		/// URL carried by an `NSUserActivity` (scene delegate or SwiftUI).
		case userActivity = "user-activity"
		/// `UIApplicationDelegate.application(_:open:options:)` (not expected with scenes).
		case appDelegateOpen = "appdelegate-open"
	}

	/// Number of queued URLs; the app observes it to drain the queue when it is ready.
	@Published private(set) var pendingCount = 0

	private var _queue: [URL] = []
	/// URL key -> time it was first received; a second delivery within the window is ignored.
	private var _recent: [String: Date] = [:]
	private static let _duplicateWindow: TimeInterval = 3
	/// Inbox copies queued during this run: key -> file identity (size + dates). The same file
	/// is never queued twice per run (no retry loops when a failed import leaves it behind), while a
	/// new copy that iOS later places at the same path (new identity) is accepted.
	private var _inboxSeen: [String: String] = [:]

	private init() {}

	/// Thread-safe; the queue itself is only touched on the main thread.
	func enqueue(_ url: URL, origin: Origin, openInPlace: Bool? = nil, sourceApplication: String? = nil) {
		guard Thread.isMainThread else {
			DispatchQueue.main.async {
				self.enqueue(url, origin: origin, openInPlace: openInPlace, sourceApplication: sourceApplication)
			}
			return
		}

		let scheme = url.scheme ?? "-"
		let ext = url.pathExtension.lowercased()
		let kind = Self.kind(of: url, openInPlace: openInPlace)
		IncomingLog.notice("Received URL: scheme=\(scheme) ext=\(ext) kind=\(kind) via=\(origin.rawValue) source=\(sourceApplication ?? "-") \(Self.typeSummary(of: url))")

		let now = Date()
		_recent = _recent.filter { now.timeIntervalSince($0.value) < Self._duplicateWindow }
		let key = Self._key(for: url)
		if _recent[key] != nil {
			IncomingLog.notice("Ignored duplicate delivery: via=\(origin.rawValue)")
			return
		}

		if kind == "inbox" {
			if let identity = Self._identity(of: url) {
				if _inboxSeen[key] == identity {
					IncomingLog.notice("Ignored Inbox file already handled in this run: via=\(origin.rawValue)")
					return
				}
				_inboxSeen[key] = identity
			} else if _inboxSeen[key] != nil {
				// Already moved away by an earlier delivery of the same file.
				IncomingLog.notice("Ignored Inbox file already imported: via=\(origin.rawValue)")
				return
			}
		}
		_recent[key] = now

		// The URL object itself is kept: for open-in-place files it carries the security-scoped access.
		_queue.append(url)
		pendingCount = _queue.count
		IncomingLog.notice("Queued URL: kind=\(kind) pending=\(self._queue.count)")
	}

	/// Logs an `NSUserActivity` and queues any URL it carries that the app can handle
	/// (`quill://` link or file URL in `webpageURL` / `userInfo`).
	func handle(_ activity: NSUserActivity, via: String) {
		let fileURLs = (activity.userInfo ?? [:]).values.compactMap { value -> URL? in
			if let url = value as? URL, url.isFileURL { return url }
			return nil
		}
		let web = activity.webpageURL
		IncomingLog.notice("User activity: via=\(via) type=\(activity.activityType) webpageURL=\(web.map { $0.scheme ?? "-" } ?? "none") userInfoKeys=\(activity.userInfo?.count ?? 0) fileURLs=\(fileURLs.count)")
		if let web, web.isFileURL || web.scheme == "quill" {
			enqueue(web, origin: .userActivity)
		}
		for url in fileURLs {
			enqueue(url, origin: .userActivity)
		}
	}

	/// Main thread only. Returns and clears all queued URLs.
	func takeAll() -> [URL] {
		let urls = _queue
		_queue.removeAll()
		if pendingCount != 0 { pendingCount = 0 }
		return urls
	}

	/// "link" (not a file), "inbox" (system copy in our container), "open-in-place"
	/// (original file outside our container), "container" (other file inside our container).
	static func kind(of url: URL, openInPlace: Bool? = nil) -> String {
		guard url.isFileURL else { return "link" }
		if isOwnInboxCopy(url) { return "inbox" }
		if openInPlace == true { return "open-in-place" }
		return isInOwnContainer(url) ? "container" : "open-in-place"
	}

	/// True only for `Documents/Inbox/<file>` or `tmp/<bundle id>-Inbox/<file>` inside our own
	/// container. Only such system copies may be moved or deleted by the incoming-file code.
	static func isOwnInboxCopy(_ url: URL) -> Bool {
		guard url.isFileURL else { return false }
		let folder = url.deletingLastPathComponent().lastPathComponent
		guard folder == "Inbox" || folder.hasSuffix("-Inbox") else { return false }
		return isInOwnContainer(url)
	}

	/// Lexical check (no file system access, so it also works for files that were moved away).
	static func isInOwnContainer(_ url: URL) -> Bool {
		guard url.isFileURL else { return false }
		let home = _normalizedPath(URL(fileURLWithPath: NSHomeDirectory()))
		return _normalizedPath(url).hasPrefix(home + "/")
	}

	/// Standardized path with a leading "/private" removed ("/private/var/..." == "/var/...").
	private static func _normalizedPath(_ url: URL) -> String {
		let path = url.standardizedFileURL.path
		return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
	}

	/// Type identifiers only (public-safe): the type the extension maps to on this device (another
	/// installed app may own `ipa`), the file's own content type and whether it counts as an IPA.
	static func typeSummary(of url: URL) -> String {
		guard url.isFileURL else { return "" }
		let byExtension = UTType(filenameExtension: url.pathExtension)
		let content = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
		let ipa = UTType("com.apple.itunes.ipa")
		let conforms = ipa.map { (content ?? byExtension)?.conforms(to: $0) ?? false } ?? false
		return "utiByExt=\(byExtension?.identifier ?? "-") contentType=\(content?.identifier ?? "-") conformsIpa=\(conforms)"
	}

	/// Public-safe summary of what iOS handed over with a scene connection.
	static func summary(of options: UIScene.ConnectionOptions) -> String {
		let types = options.userActivities.map(\.activityType).joined(separator: ",")
		return "urlContexts=\(options.urlContexts.count) userActivities=\(options.userActivities.count) activityTypes=[\(types)] handoff=\(options.handoffUserActivityType ?? "-") shortcutItem=\(options.shortcutItem != nil) sourceApp=\(options.sourceApplication ?? "-") notification=\(options.notificationResponse != nil)"
	}

	/// Purely lexical (no file system access): the file may already have been moved away when a
	/// second delivery arrives, so "/private/var/..." and "/var/..." must give the same key.
	private static func _key(for url: URL) -> String {
		url.isFileURL ? _normalizedPath(url) : url.absoluteString
	}

	/// Size and dates of an existing file; nil when it does not exist (any more).
	private static func _identity(of url: URL) -> String? {
		guard
			FileManager.default.fileExists(atPath: url.path),
			let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
		else { return nil }
		let created = values.creationDate?.timeIntervalSince1970 ?? 0
		let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
		return "\(values.fileSize ?? -1)|\(created)|\(modified)"
	}
}

/// Fallback for share-sheet "Copy to Quill" deliveries that arrive without any URL (seen on
/// iOS 27: the scene connects with no URL contexts and no `openURLContexts` call follows).
/// iOS copies such files into `Documents/Inbox` (older systems) or `tmp/<bundle id>-Inbox`
/// (current systems). Every file found there is queued through `IncomingURLRouter`, so the
/// normal readiness, de-duplication and error handling apply. Quill's own folders are never touched.
///
/// Only files that iOS created since the previous app run started are imported (left-overs from
/// older versions must never be imported or restored unasked). Older copies are deleted: they are
/// iOS's own copies, the originals stay in the sharing app.
enum IncomingInboxScanner {
	private static let _queue = DispatchQueue(label: "Quill.IncomingInboxScanner", qos: .userInitiated)
	private static let _runStartKey = "Quill.incoming.lastRunStart"
	/// Used when no previous run start is stored (first launch of this build, or after Reset All).
	private static let _firstRunWindow: TimeInterval = 5 * 60
	/// Files created before this date are not imported. Set once per run by `recordRunStart()`.
	private static var _cutoff: Date?

	/// Call once per app run, before the first scan: remembers the previous run's start as the
	/// cutoff and stores this run's start for the next one.
	static func recordRunStart() {
		let now = Date()
		let previous = UserDefaults.standard.object(forKey: _runStartKey) as? Date
		let cutoff: Date
		if let previous, previous <= now {
			cutoff = previous
		} else {
			// No stored start, or the clock went backwards: only the last few minutes count.
			cutoff = now.addingTimeInterval(-_firstRunWindow)
		}
		_queue.sync { Self._cutoff = cutoff }
		UserDefaults.standard.set(now, forKey: _runStartKey)
		IncomingLog.notice("Inbox cutoff: previousRunStored=\(previous != nil)")
	}

	static func scan(reason: String) {
		_queue.async {
			// Without a cutoff, stay on the safe side and import nothing.
			guard let cutoff = Self._cutoff else {
				IncomingLog.error("Inbox scan skipped: no cutoff recorded")
				return
			}
			let fileManager = FileManager.default
			var folders = [URL.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)]
			let tmp = fileManager.temporaryDirectory
			if let names = try? fileManager.contentsOfDirectory(atPath: tmp.path) {
				folders += names
					.filter { $0.hasSuffix("-Inbox") }
					.map { tmp.appendingPathComponent($0, isDirectory: true) }
			}

			var found: [URL] = []
			for folder in folders {
				guard let items = try? fileManager.contentsOfDirectory(
					at: folder,
					includingPropertiesForKeys: [.isRegularFileKey],
					options: [.skipsHiddenFiles]
				) else { continue }
				found += items.filter {
					(try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
				}
			}

			var fresh: [URL] = []
			var removedOld = 0
			var undated = 0
			for url in found where IncomingURLRouter.isOwnInboxCopy(url) {
				guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate else {
					undated += 1
					continue
				}
				if created >= cutoff {
					fresh.append(url)
				} else if (try? fileManager.removeItem(at: url)) != nil {
					removedOld += 1
				}
			}

			let extensions = found.map { $0.pathExtension.lowercased() }.map { $0.isEmpty ? "(none)" : $0 }
			if !found.isEmpty || reason == "launch" {
				IncomingLog.notice("Inbox scan: reason=\(reason) folders=\(folders.count) files=\(found.count) ext=[\(extensions.joined(separator: ","))] new=\(fresh.count) removedOld=\(removedOld) undatedSkipped=\(undated)")
			}
			for url in fresh {
				IncomingURLRouter.shared.enqueue(url, origin: .inboxScan)
			}
		}
	}
}

/// Receives URLs at the UIKit scene level. SwiftUI creates this delegate (see
/// `AppDelegate.application(_:configurationForConnecting:options:)`) and forwards scene callbacks to it.
final class QuillSceneDelegate: NSObject, UIWindowSceneDelegate {
	func scene(
		_ scene: UIScene,
		willConnectTo session: UISceneSession,
		options connectionOptions: UIScene.ConnectionOptions
	) {
		IncomingLog.notice("Scene willConnect: \(IncomingURLRouter.summary(of: connectionOptions))")
		for context in connectionOptions.urlContexts {
			IncomingURLRouter.shared.enqueue(
				context.url,
				origin: .sceneConnect,
				openInPlace: context.options.openInPlace,
				sourceApplication: context.options.sourceApplication
			)
		}
		for activity in connectionOptions.userActivities {
			IncomingURLRouter.shared.handle(activity, via: "scene-connect")
		}
	}

	func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
		IncomingLog.notice("Scene openURLContexts: count=\(URLContexts.count)")
		for context in URLContexts {
			IncomingURLRouter.shared.enqueue(
				context.url,
				origin: .sceneOpen,
				openInPlace: context.options.openInPlace,
				sourceApplication: context.options.sourceApplication
			)
		}
	}

	func scene(_ scene: UIScene, willContinueUserActivityWithType userActivityType: String) {
		IncomingLog.notice("Scene willContinueUserActivity: type=\(userActivityType)")
	}

	func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
		IncomingURLRouter.shared.handle(userActivity, via: "scene-continue")
	}

	func windowScene(
		_ windowScene: UIWindowScene,
		performActionFor shortcutItem: UIApplicationShortcutItem,
		completionHandler: @escaping (Bool) -> Void
	) {
		IncomingLog.notice("Scene shortcut item: type=\(shortcutItem.type)")
		completionHandler(false)
	}
}
