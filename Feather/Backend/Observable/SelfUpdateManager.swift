//
//  SelfUpdateManager.swift
//  Quill
//
//  Checks a user-configured source for a newer version of Quill itself. Informational only:
//  it never downloads or installs anything, it just reports and opens the page.
//

import Foundation
import UIKit

/// True when `identifier` is the running bundle ID `own`, or `own` is `identifier` plus exactly one
/// extra component (SideStore/AltStore suffixing). Identifiers without a "." never match by prefix.
func bundleIDMatchesRunningApp(_ identifier: String, own: String) -> Bool {
	guard identifier.contains(".") else { return false }
	if identifier == own { return true }
	guard own.hasPrefix(identifier + ".") else { return false }
	let suffix = own.dropFirst(identifier.count + 1)
	return !suffix.isEmpty && !suffix.contains(".")
}

/// Bundle IDs are compared case-insensitively (as iOS does).
func sameBundleID(_ a: String, _ b: String) -> Bool {
	a.caseInsensitiveCompare(b) == .orderedSame
}

/// True for the release ID (`app.quill.sign`) or the release ID plus exactly one extra component
/// (SideStore/AltStore suffixing, e.g. "app.quill.sign.TEAMID"). The prefix rule applies only to
/// the release ID; any other identifier must match exactly.
func isQuillReleaseBundleID(_ identifier: String) -> Bool {
	sameBundleID(identifier, quillCanonicalBundleID)
		|| bundleIDMatchesRunningApp(quillCanonicalBundleID, own: identifier.lowercased())
}

/// True when installing an app with `identifier` replaces the running app: exact match, or the
/// release ID while the running copy carries a SideStore/AltStore suffix.
func bundleIDReplacesRunningApp(_ identifier: String) -> Bool {
	guard let own = Bundle.main.bundleIdentifier, !identifier.isEmpty else { return false }
	if sameBundleID(identifier, own) { return true }
	return sameBundleID(identifier, quillCanonicalBundleID)
		&& bundleIDMatchesRunningApp(quillCanonicalBundleID, own: own.lowercased())
}

/// Source entries: Quill is listed under the release ID; an entry with the running app's exact ID
/// is accepted too (a source published for a copy installed under the profile's App ID).
func isQuillBundleID(_ identifier: String) -> Bool {
	if isQuillReleaseBundleID(identifier) { return true }
	guard let own = Bundle.main.bundleIdentifier else { return false }
	return sameBundleID(identifier, own)
}

/// Caches the executable check per library item (reading Info.plist from disk for every cell).
private let _quillExecutableCache = NSCache<NSString, NSNumber>()

extension AppInfoPresentable {
	/// True when this library item is Quill itself. The release ID (`app.quill.sign`, also with a
	/// SideStore/AltStore suffix) always counts. An item carrying the running app's ID (Quill installed
	/// under the profile's App ID, e.g. "com.example.app") counts only if its executable is Quill's, so another
	/// app that was given this ID is never mistaken for Quill. Determined at runtime (no schema change).
	var isQuillItself: Bool {
		guard let identifier, !identifier.isEmpty else { return false }
		if isQuillReleaseBundleID(identifier) { return true }
		guard let own = Bundle.main.bundleIdentifier, sameBundleID(identifier, own) else { return false }
		return _hasQuillExecutable
	}
	
	/// True only when installing this item replaces the running app (its bundle ID is the running
	/// app's). A Quill IPA with another ID installs as a separate copy; a non-Quill app with this ID
	/// would replace Quill (see `InstallPreviewView`).
	var replacesRunningApp: Bool {
		guard let identifier else { return false }
		return bundleIDReplacesRunningApp(identifier)
	}
	
	/// CFBundleExecutable of the item's .app equals the running app's. False when unreadable.
	private var _hasQuillExecutable: Bool {
		let key = (uuid ?? "") as NSString
		if let cached = _quillExecutableCache.object(forKey: key) { return cached.boolValue }
		var result = false
		if
			let own = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
			let appURL = Storage.shared.getAppDirectory(for: self),
			let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
			let executable = info["CFBundleExecutable"] as? String
		{
			result = executable == own
		}
		if uuid != nil { _quillExecutableCache.setObject(NSNumber(value: result), forKey: key) }
		return result
	}
}

@MainActor
final class SelfUpdateManager: ObservableObject {
	static let shared = SelfUpdateManager()
	
	static let sourceURLKey = "Quill.selfUpdate.sourceURL"
	static let autoCheckKey = "Quill.selfUpdate.autoCheck"
	/// Official Quill AltStore-style source, published by the release workflow.
	static let defaultSourceURL = "https://raw.githubusercontent.com/SimonPetrus/Quill/source/source.json"
	static let ownSourceIdentifier = "app.quill.source"
	static let didAddOwnSourceKey = "Quill.didAddOwnSource"
	private static let _lastAutoCheckKey = "Quill.selfUpdate.lastAutoCheck"
	
	enum Status: Equatable {
		case idle
		case checking
		case upToDate(String)
		case available(version: String, url: URL)
		case failed(String)
	}
	
	@Published private(set) var status: Status = .idle
	
	private init() {}
	
	/// Configured source URL; the official one when never set (an explicitly emptied value stays empty).
	private static func _configuredSourceURL() -> String {
		let defaults = UserDefaults.standard
		guard let stored = defaults.string(forKey: sourceURLKey) else { return defaultSourceURL }
		return stored.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	
	private var _currentVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
	}
	
	// MARK: Version comparison
	
	/// Numeric, component-wise comparison ("v" prefix ignored; missing components count as 0).
	/// Returns a negative value when `a < b`, 0 when equal, positive when `a > b`.
	/// Tags that don't start with a digit ("Quill-1.2") use the first digit run onward; a pre-release
	/// suffix ("1.2-beta") sorts below the stable release with the same numbers.
	nonisolated static func compareVersions(_ a: String, _ b: String) -> Int {
		func parse(_ s: String) -> (nums: [Int], pre: String?) {
			let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
			guard let start = t.firstIndex(where: { $0.isNumber }) else { return ([0], nil) }
			let rest = t[start...]
			var numeric = rest
			var pre: String? = nil
			if let dash = rest.firstIndex(where: { $0 == "-" || $0 == "+" }) {
				numeric = rest[..<dash]
				if rest[dash] == "-" {
					let suffix = String(rest[rest.index(after: dash)...])
					pre = suffix.isEmpty ? nil : suffix.lowercased()
				}
			}
			let nums = numeric.split(separator: ".").map { comp in
				Int(comp.prefix(while: { $0.isNumber })) ?? 0
			}
			return (nums, pre)
		}
		let x = parse(a), y = parse(b)
		for i in 0..<max(x.nums.count, y.nums.count) {
			let l = i < x.nums.count ? x.nums[i] : 0
			let r = i < y.nums.count ? y.nums[i] : 0
			if l != r { return l < r ? -1 : 1 }
		}
		switch (x.pre, y.pre) {
		case (nil, nil): return 0
		case (nil, _): return 1
		case (_, nil): return -1
		case let (p?, q?): return p == q ? 0 : (p < q ? -1 : 1)
		}
	}
	
	// MARK: Check
	
	func check() async {
		guard status != .checking else { return }
		
		let raw = Self._configuredSourceURL()
		guard
			!raw.isEmpty,
			let url = URL(string: raw),
			let scheme = url.scheme?.lowercased(),
			scheme == "https" || scheme == "http"
		else {
			status = .failed(.localized("The update source URL is not valid."))
			return
		}
		
		status = .checking
		do {
			var request = URLRequest(url: url, timeoutInterval: 20)
			request.setValue("application/json", forHTTPHeaderField: "Accept")
			let (data, response) = try await URLSession.shared.data(for: request)
			if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
				status = .failed(.localized("The update source returned an error (%@).", arguments: "\(http.statusCode)"))
				return
			}
			
			guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				status = .failed(.localized("The update source could not be read."))
				return
			}
			
			guard let (version, link) = Self._parse(json, sourceURL: url) else {
				status = .failed(.localized("Quill was not found in the update source."))
				return
			}
			
			if Self.compareVersions(_currentVersion, version) < 0 {
				status = .available(version: version, url: link)
			} else {
				status = .upToDate(_currentVersion)
			}
		} catch {
			status = .failed(error.localizedDescription)
		}
	}
	
	/// GitHub Releases API (`.../repos/<owner>/<repo>/releases/latest`) or an AltStore-style source.
	private static func _parse(_ json: [String: Any], sourceURL: URL) -> (String, URL)? {
		if sourceURL.host?.lowercased() == "api.github.com", sourceURL.path.hasPrefix("/repos/") {
			guard
				let tag = json["tag_name"] as? String,
				let html = json["html_url"] as? String,
				let link = URL(string: html)
			else { return nil }
			return (tag, link)
		}
		
		guard
			let apps = json["apps"] as? [[String: Any]],
			// The source lists the release ID; the installed copy may run under the profile's App ID.
			let app = apps.first(where: { isQuillBundleID(($0["bundleIdentifier"] as? String) ?? "") })
		else { return nil }
		
		let latest = (app["versions"] as? [[String: Any]])?.first
		guard let version = (latest?["version"] as? String) ?? (app["version"] as? String) else { return nil }
		
		// Prefer the source's page, then the direct download.
		let candidates = [json["website"] as? String, latest?["downloadURL"] as? String, app["downloadURL"] as? String]
		guard
			let link = candidates.compactMap({ $0 }).compactMap({ URL(string: $0) }).first(where: {
				["http", "https"].contains($0.scheme?.lowercased() ?? "")
			})
		else { return nil }
		return (version, link)
	}
	
	// MARK: Launch check
	
	/// Result of a launch check that still has to be shown (no presenter yet, or another alert was up).
	private var _pendingAlert: (version: String, url: URL)?
	
	/// At most once a day, silent unless a newer version exists. Only runs when enabled and a source is set.
	/// The day only counts once a check actually produced a result.
	func autoCheckIfNeeded() {
		let defaults = UserDefaults.standard
		guard
			defaults.bool(forKey: Self.autoCheckKey),
			!Self._configuredSourceURL().isEmpty
		else { return }
		
		let last = defaults.object(forKey: Self._lastAutoCheckKey) as? Date
		if let last, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
		
		Task {
			await check()
			switch status {
			case .available(let version, let url):
				defaults.set(Date(), forKey: Self._lastAutoCheckKey)
				_pendingAlert = (version, url)
				presentPendingIfPossible()
			case .upToDate:
				defaults.set(Date(), forKey: Self._lastAutoCheckKey)
			default:
				break
			}
		}
	}
	
	/// Shows the stored update alert once a presenter exists and nothing else (startup notice, another
	/// alert) is in the way; otherwise it stays pending for the next time the app becomes active.
	func presentPendingIfPossible() {
		guard
			let pending = _pendingAlert,
			Storage.startupNotice == nil,
			let presenter = UIApplication.topViewController(),
			presenter.presentedViewController == nil,
			!(presenter is UIAlertController)
		else { return }
		_pendingAlert = nil
		
		UIAlertController.showAlert(
			presenter,
			title: .localized("Update Available"),
			message: .localized("Quill %@ is available.", arguments: pending.version),
			actions: [
				UIAlertAction(title: .localized("Open"), style: .default) { _ in
					UIApplication.shared.open(pending.url)
				},
				UIAlertAction(title: .localized("Cancel"), style: .cancel)
			]
		)
	}
}
