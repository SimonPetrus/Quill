//
//  SelfUpdateManager.swift
//  Quill
//
//  Checks a user-configured source for a newer version of Quill itself. Informational only:
//  it never downloads or installs anything, it just reports and opens the page.
//

import Foundation
import UIKit

extension AppInfoPresentable {
	/// True when this library item is Quill itself (same bundle ID as the running app).
	/// Determined at runtime so no Core Data schema change is needed.
	var isQuillItself: Bool {
		guard let identifier, let own = Bundle.main.bundleIdentifier else { return false }
		return identifier == own
	}
}

@MainActor
final class SelfUpdateManager: ObservableObject {
	static let shared = SelfUpdateManager()
	
	static let sourceURLKey = "Quill.selfUpdate.sourceURL"
	static let autoCheckKey = "Quill.selfUpdate.autoCheck"
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
	
	private var _currentVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
	}
	
	// MARK: Version comparison
	
	/// Numeric, component-wise comparison ("v" prefix ignored; missing components count as 0).
	/// Returns a negative value when `a < b`, 0 when equal, positive when `a > b`.
	nonisolated static func compareVersions(_ a: String, _ b: String) -> Int {
		func parts(_ s: String) -> [Int] {
			var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
			if t.lowercased().hasPrefix("v") { t.removeFirst() }
			return t.split(separator: ".").map { comp in
				Int(comp.prefix(while: { $0.isNumber })) ?? 0
			}
		}
		let x = parts(a), y = parts(b)
		for i in 0..<max(x.count, y.count) {
			let l = i < x.count ? x[i] : 0
			let r = i < y.count ? y[i] : 0
			if l != r { return l < r ? -1 : 1 }
		}
		return 0
	}
	
	// MARK: Check
	
	func check() async {
		guard status != .checking else { return }
		
		let raw = (UserDefaults.standard.string(forKey: Self.sourceURLKey) ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
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
			let own = Bundle.main.bundleIdentifier,
			let app = apps.first(where: { ($0["bundleIdentifier"] as? String) == own })
		else { return nil }
		
		let latest = (app["versions"] as? [[String: Any]])?.first
		guard let version = (latest?["version"] as? String) ?? (app["version"] as? String) else { return nil }
		
		let candidates = [latest?["downloadURL"] as? String, app["downloadURL"] as? String, json["website"] as? String]
		guard
			let link = candidates.compactMap({ $0 }).compactMap({ URL(string: $0) }).first(where: {
				["http", "https"].contains($0.scheme?.lowercased() ?? "")
			})
		else { return nil }
		return (version, link)
	}
	
	// MARK: Launch check
	
	/// At most once a day, silent unless a newer version exists. Only runs when enabled and a source is set.
	func autoCheckIfNeeded() {
		let defaults = UserDefaults.standard
		guard
			defaults.bool(forKey: Self.autoCheckKey),
			!(defaults.string(forKey: Self.sourceURLKey) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
		else { return }
		
		let last = defaults.object(forKey: Self._lastAutoCheckKey) as? Date
		if let last, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
		defaults.set(Date(), forKey: Self._lastAutoCheckKey)
		
		Task {
			await check()
			guard case .available(let version, let url) = status else { return }
			UIAlertController.showAlert(
				title: .localized("Update Available"),
				message: .localized("Quill %@ is available.", arguments: version),
				actions: [
					UIAlertAction(title: .localized("Open"), style: .default) { _ in
						UIApplication.shared.open(url)
					},
					UIAlertAction(title: .localized("Cancel"), style: .cancel)
				]
			)
		}
	}
}
