//
//  AppUpdateChecker.swift
//  Quill
//
//  Automatic check of the library apps against their repositories: at launch / when the app
//  becomes active (at most every 6 hours) and, optionally, in the background with a local
//  notification. Results go to the shared `UpdateManager`, so the Library badges update too.
//

import BackgroundTasks
import CoreData
import Foundation
import OSLog
import UIKit
import UserNotifications

@MainActor
final class AppUpdateChecker {
	static let shared = AppUpdateChecker()

	/// Settings switch: check on launch / activation (default on).
	static let autoCheckKey = "Quill.appUpdates.autoCheck"
	/// Settings switch: background check with a notification (default off).
	static let backgroundNotifyKey = "Quill.appUpdates.backgroundNotify"
	private static let _lastCheckKey = "Quill.appUpdates.lastCheck"
	private static let _notifiedKey = "Quill.appUpdates.notified"

	/// Fixed on purpose (not derived from the bundle ID): Quill is re-signed under other bundle IDs.
	/// Must match the literal entry in Info.plist (BGTaskSchedulerPermittedIdentifiers).
	nonisolated static let refreshTaskID = "app.quill.sign.appUpdateRefresh"
	nonisolated static let notificationID = "quill.appupdate"

	private static let _interval: TimeInterval = 6 * 60 * 60
	private static let _maxRemembered = 200

	private var _isRunning = false
	/// Updates that still have to be announced (no presenter yet, or another alert was up).
	private var _pending: [AppUpdate] = []

	private init() {}

	nonisolated static var isAutoCheckEnabled: Bool {
		UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true
	}

	nonisolated static var isBackgroundNotifyEnabled: Bool {
		UserDefaults.standard.bool(forKey: backgroundNotifyKey)
	}

	// MARK: Scan

	/// Reads the stored sources and library apps (main-thread Core Data) and refreshes the shared
	/// `UpdateManager`. False when nothing could be checked (no sources, offline, already running).
	private enum ScanResult { case checked, nothingToDo, failed }
	
	private func _scan() async -> ScanResult {
		guard !_isRunning else { return .failed }
		_isRunning = true
		defer { _isRunning = false }

		let context = Storage.shared.context
		let sources = (try? context.fetch(AltSource.fetchRequest() as NSFetchRequest<AltSource>)) ?? []
		guard !sources.isEmpty else { return .nothingToDo }
		let signed = (try? context.fetch(Signed.fetchRequest() as NSFetchRequest<Signed>)) ?? []
		let imported = (try? context.fetch(Imported.fetchRequest() as NSFetchRequest<Imported>)) ?? []
		let localApps = signed.map { $0 as AppInfoPresentable } + imported.map { $0 as AppInfoPresentable }
		guard !localApps.isEmpty else { return .nothingToDo }

		return await UpdateManager.shared.checkForUpdates(sources: sources, localApps: localApps) ? .checked : .failed
	}

	// MARK: Notified keys

	private static func _key(_ update: AppUpdate) -> String {
		"\(update.bundleIdentifier.lowercased())|\(update.remoteVersion)"
	}

	private static func _notified() -> [String] {
		UserDefaults.standard.stringArray(forKey: _notifiedKey) ?? []
	}

	/// Current updates not announced yet, one per bundle ID + version, sorted by name.
	private func _unannounced() -> [AppUpdate] {
		let known = Set(Self._notified())
		var seen = Set<String>()
		var result: [AppUpdate] = []
		for update in UpdateManager.shared.updates.values.sorted(by: { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }) {
			let key = Self._key(update)
			guard !known.contains(key), seen.insert(key).inserted else { continue }
			result.append(update)
		}
		return result
	}

	private func _markAnnounced(_ updates: [AppUpdate]) {
		var list = Self._notified()
		for update in updates {
			let key = Self._key(update)
			if !list.contains(key) { list.append(key) }
		}
		if list.count > Self._maxRemembered { list.removeFirst(list.count - Self._maxRemembered) }
		UserDefaults.standard.set(list, forKey: Self._notifiedKey)
	}

	/// "A, B, C and 2 more".
	private static func _summary(_ updates: [AppUpdate]) -> String {
		let shown = 3
		let names = updates.prefix(shown).map(\.appName).joined(separator: ", ")
		guard updates.count > shown else { return names }
		return .localized("%@ and %@ more", arguments: names, "\(updates.count - shown)")
	}

	// MARK: Foreground check

	/// Launch / activation check: at most every 6 hours, silent unless there is a new update.
	/// The interval only counts once a check actually produced a result (offline stays silent
	/// and is retried the next time the app becomes active).
	func autoCheckIfNeeded() {
		guard Self.isAutoCheckEnabled else { return }
		let defaults = UserDefaults.standard
		if let last = defaults.object(forKey: Self._lastCheckKey) as? Date,
		   Date().timeIntervalSince(last) < Self._interval { return }

		Task {
			guard await _scan() == .checked else { return }
			defaults.set(Date(), forKey: Self._lastCheckKey)
			let fresh = _unannounced()
			guard !fresh.isEmpty else { return }
			_pending = fresh
			presentPendingIfPossible()
		}
	}

	/// Shows the alert once a presenter exists and nothing else (startup notice, another alert,
	/// the Quill self-update alert) is in the way; otherwise it stays pending for the next activation.
	func presentPendingIfPossible() {
		guard
			Self.isAutoCheckEnabled,
			!_pending.isEmpty,
			Storage.startupNotice == nil,
			let presenter = UIApplication.topViewController(),
			presenter.presentedViewController == nil,
			!(presenter is UIAlertController)
		else { return }

		// Drop entries that were announced meanwhile (e.g. by a background notification) or are gone.
		let current = Set(UpdateManager.shared.updates.values.map { Self._key($0) })
		let known = Set(Self._notified())
		let toShow = _pending.filter { current.contains(Self._key($0)) && !known.contains(Self._key($0)) }
		_pending = []
		guard !toShow.isEmpty else { return }
		_markAnnounced(toShow)

		UIAlertController.showAlert(
			presenter,
			title: .localized("App Updates Available"),
			message: Self._summary(toShow),
			actions: [
				UIAlertAction(title: .localized("Show"), style: .default) { _ in
					TabRouter.shared.requestLibrary()
				},
				UIAlertAction(title: .localized("Later"), style: .cancel)
			]
		)
	}

	// MARK: Background refresh

	/// Must be called before `application(_:didFinishLaunchingWithOptions:)` returns.
	nonisolated static func registerBackgroundTask() {
		BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
			guard let task = task as? BGAppRefreshTask else {
				task.setTaskCompleted(success: false)
				return
			}
			handleBackgroundRefresh(task)
		}
	}

	/// Requests the next refresh ~6 hours out, or cancels it when background checks are off.
	nonisolated static func scheduleBackgroundRefresh() {
		guard isBackgroundNotifyEnabled else {
			cancelBackgroundRefresh()
			return
		}
		submitRefreshRequest()
	}
	
	/// Submits the next refresh; `onlyIfNone` keeps an already pending request (and its date) as is,
	/// so going to the background repeatedly does not keep pushing the date out.
	nonisolated private static func submitRefreshRequest(onlyIfNone: Bool = true) {
		BGTaskScheduler.shared.getPendingTaskRequests { pending in
			// The switch may have been turned off while this callback was waiting.
			guard isBackgroundNotifyEnabled else { return }
			if onlyIfNone, pending.contains(where: { $0.identifier == refreshTaskID }) { return }
			let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
			request.earliestBeginDate = Date(timeIntervalSinceNow: _interval)
			do {
				try BGTaskScheduler.shared.submit(request)
			} catch {
				Logger.misc.error("App update refresh could not be scheduled: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	nonisolated static func cancelBackgroundRefresh() {
		BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskID)
		UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
	}

	private final class _Completion: @unchecked Sendable {
		private let _lock = NSLock()
		private var _done = false
		private let _task: BGAppRefreshTask
		init(_ task: BGAppRefreshTask) { _task = task }

		/// Completes the task exactly once.
		func finish(success: Bool) {
			_lock.lock()
			let already = _done
			_done = true
			_lock.unlock()
			if !already { _task.setTaskCompleted(success: success) }
		}
	}

	nonisolated private static func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
		// Always line up the next run first (the running task's own request is already consumed).
		if isBackgroundNotifyEnabled { submitRefreshRequest(onlyIfNone: false) }

		let completion = _Completion(task)
		// Core Data's view context is main-thread only, so the whole job runs on the main actor.
		let work = Task { @MainActor in
			guard isBackgroundNotifyEnabled else {
				completion.finish(success: true)
				return
			}
			let result = await shared._scan()
			if result == .checked, !Task.isCancelled {
				await shared._notifyNewUpdates()
			}
			completion.finish(success: result != .failed)
		}
		task.expirationHandler = {
			work.cancel()
			completion.finish(success: false)
		}
	}

	private func _notifyNewUpdates() async {
		let center = UNUserNotificationCenter.current()
		let settings = await center.notificationSettings()
		guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

		let fresh = _unannounced()
		guard !fresh.isEmpty else { return }

		let content = UNMutableNotificationContent()
		content.title = fresh.count == 1
			? .localized("App update available")
			: .localized("%@ app updates available", arguments: "\(fresh.count)")
		content.body = Self._summary(fresh)
		content.sound = .default

		let request = UNNotificationRequest(
			identifier: Self.notificationID,
			content: content,
			trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
		)
		do {
			try await center.add(request)
			_markAnnounced(fresh)
		} catch {
			Logger.misc.error("App update notification failed: \(error.localizedDescription, privacy: .public)")
		}
	}
}
