//
//  IncomingURLRouter.swift
//  Quill
//

import Foundation
import Combine
import UIKit
import OSLog

/// Single entry point for every URL handed to the app: files from "Open in" / the share sheet
/// (Files, Telegram, Safari, ...) and `quill://` links.
///
/// URLs can arrive before any UI exists (cold launch: the scene's connection options) and the same
/// URL can arrive twice through different paths (scene delegate and SwiftUI `onOpenURL`). They are
/// queued here, de-duplicated, and handed to the app only once it is ready (scene active and root
/// view on screen), so a progress item and any error alert can actually be shown.
///
/// Logging: only the scheme, the extension, the kind of source and the stage are public; file
/// paths and names are never logged.
final class IncomingURLRouter: ObservableObject {
	static let shared = IncomingURLRouter()

	enum Origin: String {
		/// `UIScene.ConnectionOptions.urlContexts` (cold launch).
		case sceneConnect = "scene-connect"
		/// `UISceneDelegate.scene(_:openURLContexts:)` (app already running).
		case sceneOpen = "scene-open"
		/// SwiftUI `onOpenURL`.
		case onOpenURL = "onOpenURL"
	}

	/// Number of queued URLs; the app observes it to drain the queue when it is ready.
	@Published private(set) var pendingCount = 0

	private var _queue: [URL] = []
	/// URL key -> time it was first received; a second delivery within the window is ignored.
	private var _recent: [String: Date] = [:]
	private static let _duplicateWindow: TimeInterval = 10

	private init() {}

	/// Thread-safe; the queue itself is only touched on the main thread.
	func enqueue(_ url: URL, origin: Origin, openInPlace: Bool? = nil) {
		guard Thread.isMainThread else {
			DispatchQueue.main.async { self.enqueue(url, origin: origin, openInPlace: openInPlace) }
			return
		}

		let scheme = url.scheme ?? "-"
		let ext = url.pathExtension.lowercased()
		let kind = Self.kind(of: url, openInPlace: openInPlace)
		Logger.incoming.notice("Received URL: scheme=\(scheme, privacy: .public) ext=\(ext, privacy: .public) kind=\(kind, privacy: .public) via=\(origin.rawValue, privacy: .public)")

		let now = Date()
		_recent = _recent.filter { now.timeIntervalSince($0.value) < Self._duplicateWindow }
		let key = Self._key(for: url)
		if _recent[key] != nil {
			Logger.incoming.notice("Ignored duplicate delivery: via=\(origin.rawValue, privacy: .public)")
			return
		}
		_recent[key] = now

		// The URL object itself is kept: for open-in-place files it carries the security-scoped access.
		_queue.append(url)
		pendingCount = _queue.count
		Logger.incoming.notice("Queued URL: kind=\(kind, privacy: .public) pending=\(self._queue.count, privacy: .public)")
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
		let folder = url.deletingLastPathComponent().lastPathComponent
		if folder == "Inbox" || folder.hasSuffix("-Inbox") { return "inbox" }
		if openInPlace == true { return "open-in-place" }
		let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
		return url.resolvingSymlinksInPath().path.hasPrefix(home + "/") ? "container" : "open-in-place"
	}

	private static func _key(for url: URL) -> String {
		url.isFileURL ? url.standardizedFileURL.resolvingSymlinksInPath().path : url.absoluteString
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
		for context in connectionOptions.urlContexts {
			IncomingURLRouter.shared.enqueue(context.url, origin: .sceneConnect, openInPlace: context.options.openInPlace)
		}
	}

	func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
		for context in URLContexts {
			IncomingURLRouter.shared.enqueue(context.url, origin: .sceneOpen, openInPlace: context.options.openInPlace)
		}
	}
}
