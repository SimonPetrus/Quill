//
//  NotificationManager.swift
//  Quill
//
//  Local notifications for certificate expiry (7 days and 1 day before) and, at launch,
//  for certificates already known to be revoked. No background checks: iOS does not run
//  those reliably, so revocation is only reported from the cached `revoked` flag.
//

import Foundation
import UserNotifications
import UIKit
import OSLog

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
	static let shared = NotificationManager()
	
	/// UserDefaults key of the Settings switch (default off).
	static let enabledKey = "Quill.certExpiryNotifications"
	private static let revokedNotifiedKey = "Quill.notifiedRevokedCertificates"
	private static let idPrefix = "quill.cert."
	
	private let center = UNUserNotificationCenter.current()
	
	private override init() { super.init() }
	
	/// Call once at launch: lets notifications show as banners while the app is in the foreground.
	func start() {
		center.delegate = self
	}
	
	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification,
		withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
	) {
		completionHandler([.banner, .list, .sound])
	}
	
	var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: Self.enabledKey)
	}
	
	/// Asks for permission; the completion runs on the main thread with the result.
	func requestAuthorization(completion: @escaping (Bool) -> Void) {
		center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
			if let error {
				Logger.misc.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
			}
			DispatchQueue.main.async { completion(granted) }
		}
	}
	
	/// Opens this app's page in the system Settings app.
	func openSystemSettings() {
		if let url = URL(string: UIApplication.openSettingsURLString) {
			UIApplication.shared.open(url)
		}
	}
	
	/// Removes every certificate notification scheduled by this manager.
	func cancelAll() {
		center.getPendingNotificationRequests { [center] requests in
			let ids = requests.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
			center.removePendingNotificationRequests(withIdentifiers: ids)
		}
	}
	
	/// Rebuilds the schedule from the stored certificates. Call after adding/deleting a certificate
	/// and at app launch. Past dates are skipped. Must be called on the main thread (Core Data).
	func reschedule() {
		guard Thread.isMainThread else {
			DispatchQueue.main.async { self.reschedule() }
			return
		}
		guard isEnabled else {
			cancelAll()
			return
		}
		
		let now = Date()
		var requests: [UNNotificationRequest] = []
		var revokedToNotify: [(uuid: String, name: String)] = []
		let alreadyNotifiedRevoked = Set(UserDefaults.standard.stringArray(forKey: Self.revokedNotifiedKey) ?? [])
		
		for cert in Storage.shared.getAllCertificates() {
			guard let uuid = cert.uuid else { continue }
			let name = cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? .localized("Unknown")
			
			if cert.revoked {
				if !alreadyNotifiedRevoked.contains(uuid) {
					revokedToNotify.append((uuid, name))
				}
				continue
			}
			
			let expiration: Date? = cert.expiration
			guard let expiration else { continue }
			
			for (suffix, days) in [("7d", 7), ("1d", 1)] {
				guard
					let fire = Calendar.current.date(byAdding: .day, value: -days, to: expiration),
					fire > now
				else { continue }
				
				let content = UNMutableNotificationContent()
				content.title = .localized("Certificate Expiring Soon")
				content.body = days == 7
					? .localized("%@ expires in 7 days.", arguments: name)
					: .localized("%@ expires tomorrow.", arguments: name)
				content.sound = .default
				
				let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
				let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
				requests.append(UNNotificationRequest(
					identifier: "\(Self.idPrefix)\(uuid).\(suffix)",
					content: content,
					trigger: trigger
				))
			}
		}
		
		// Only the expiry requests are replaced; ".revoked" requests are left alone.
		center.getPendingNotificationRequests { [center] pending in
			let stale = pending.map(\.identifier).filter {
				$0.hasPrefix(Self.idPrefix) && ($0.hasSuffix(".7d") || $0.hasSuffix(".1d"))
			}
			center.removePendingNotificationRequests(withIdentifiers: stale)
			for request in requests {
				center.add(request) { error in
					if let error {
						Logger.misc.error("Scheduling notification failed: \(error.localizedDescription, privacy: .public)")
					}
				}
			}
		}
		
		// Revoked certificates (already known from the last check) are reported once. A certificate is
		// marked as notified only after the system accepted the request and notifications are allowed.
		let toNotify = revokedToNotify
		guard !toNotify.isEmpty else { return }
		center.getNotificationSettings { [center] settings in
			guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
			for item in toNotify {
				let content = UNMutableNotificationContent()
				content.title = .localized("Certificate Revoked")
				content.body = .localized("%@ has been revoked and can no longer sign apps.", arguments: item.name)
				content.sound = .default
				let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
				let request = UNNotificationRequest(
					identifier: "\(Self.idPrefix)\(item.uuid).revoked",
					content: content,
					trigger: trigger
				)
				center.add(request) { error in
					guard error == nil else {
						Logger.misc.error("Scheduling revoked notification failed: \(error!.localizedDescription, privacy: .public)")
						return
					}
					DispatchQueue.main.async {
						var notified = Set(UserDefaults.standard.stringArray(forKey: Self.revokedNotifiedKey) ?? [])
						notified.insert(item.uuid)
						UserDefaults.standard.set(Array(notified), forKey: Self.revokedNotifiedKey)
					}
				}
			}
		}
	}
}
