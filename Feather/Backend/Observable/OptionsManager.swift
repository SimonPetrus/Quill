//
//  OptionsManager.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import Foundation
import UIKit
import OSLog

// MARK: - OptionsManager
class OptionsManager: ObservableObject {
	static let shared = OptionsManager()
	
	static let storageKey = "signing_options"
	private let _key = OptionsManager.storageKey
	
	@Published var options: Options {
		didSet {
			saveOptions()
		}
	}
	
	init() {
		let defaults = Options.defaultOptions
		
		if let data = UserDefaults.standard.data(forKey: _key) {
			let (restored, repaired) = Self.restore(from: data, defaults: defaults)
			self.options = restored
			// Write the repaired value back so the corruption does not persist.
			if repaired, let encoded = try? JSONEncoder().encode(restored) {
				UserDefaults.standard.set(encoded, forKey: _key)
			}
			return
		}
		
		self.options = defaults
		
		if let encoded = try? JSONEncoder().encode(defaults) {
			UserDefaults.standard.set(encoded, forKey: _key)
		}
	}
	
	/// Field-by-field tolerant restore: every saved field is applied on top of the
	/// defaults only if the result still decodes, so one bad/mistyped field resets
	/// just that field instead of discarding all the user's settings.
	/// - Returns: the options and whether anything had to be repaired.
	static func restore(from data: Data, defaults: Options) -> (Options, Bool) {
		guard
			let savedDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let defaultData = try? JSONEncoder().encode(defaults),
			var merged = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any]
		else {
			Logger.misc.error("Signing options unreadable, falling back to defaults")
			return (defaults, true)
		}
		
		// Optional fields are omitted from the encoded defaults, so list them explicitly.
		let known = Set(merged.keys).union(["appName", "appVersion", "appIdentifier", "appEntitlementsFile"])
		var repaired = false
		
		for (key, value) in savedDict {
			guard known.contains(key) else {
				Logger.misc.error("Signing options: dropping unknown field '\(key, privacy: .public)'")
				repaired = true
				continue
			}
			var candidate = merged
			candidate[key] = value
			if
				JSONSerialization.isValidJSONObject(candidate),
				let candidateData = try? JSONSerialization.data(withJSONObject: candidate),
				(try? JSONDecoder().decode(Options.self, from: candidateData)) != nil
			{
				merged = candidate
			} else {
				Logger.misc.error("Signing options: invalid value for '\(key, privacy: .public)', using default")
				repaired = true
			}
		}
		
		if
			let mergedData = try? JSONSerialization.data(withJSONObject: merged),
			let options = try? JSONDecoder().decode(Options.self, from: mergedData)
		{
			return (options, repaired)
		}
		return (defaults, true)
	}
	
	/// Saves options
	func saveOptions() {
		if let encoded = try? JSONEncoder().encode(options) {
			UserDefaults.standard.set(encoded, forKey: _key)
		}
	}
}

// MARK: - Options
struct Options: Codable, Equatable {
	
	// MARK: Pre Modifications
	
	/// App name
	var appName: String?
	/// App version
	var appVersion: String?
	/// App bundle identifer
	var appIdentifier: String?
	/// App entitlements
	var appEntitlementsFile: URL?
	/// App apparence (i.e. Light/Dark/Default)
	var appAppearance: AppAppearance
	/// App minimum iOS requirement (i.e. iOS 11.0)
	var minimumAppRequirement: MinimumAppRequirement
	/// Signing options
	var signingOption: SigningOption
	
	// MARK: Options
	
	/// Inject path (i.e. `@rpath`)
	var injectPath: InjectPath
	/// Inject folder (i.e. `Frameworks/`)
	var injectFolder: InjectFolder
	/// Random string appended to the app identifier
	var ppqString: String
	/// Basic protection against PPQ
	var ppqProtection: Bool
	/// (Better) protection against PPQ
	var dynamicProtection: Bool
	/// App identifiers list which matches and replaces
	var identifiers: [String: String]
	/// App name list which matches and replaces
	var displayNames: [String: String]
	/// Array of files (`.dylib`, `.deb` ) to extract and inject
	var injectionFiles: [URL]
	/// Mach-o load paths to remove (i.e. `@executable_path/demo1.dylib`)
	var disInjectionFiles: [String]
	/// App files to remove from (i.e. `Frameworks/CydiaSubstrate.framework`)
	var removeFiles: [String]
	/// If app should have filesharing forcefully enabled
	var fileSharing: Bool
	/// If app should have iTunes filesharing forcefully enabled
	var itunesFileSharing: Bool
	/// If app should have Pro Motion enabled (may not be needed)
	var proMotion: Bool
	/// If app should have Game Mode enabled
	var gameMode: Bool
	/// If app should use fullscreen (iPad mainly)
	var ipadFullscreen: Bool
	/// If app shouldn't have URL Schemes
	var removeURLScheme: Bool
	/// If app should not include a `embedded.mobileprovision` (useful for JB detection)
	var removeProvisioning: Bool
	/// If the whole `Watch/` folder should be removed from the app
	var removeWatchApp: Bool
	/// Forcefully rename string files for App name
	var changeLanguageFilesForCustomDisplayName: Bool
	/// If tweaks should be injected into all app extensions (PlugIns and Extensions)
	var injectIntoExtensions: Bool
	/// If tweaks should also be injected into the Watch app(s) and their extensions
	var injectIntoWatchApp: Bool
	/// If app should merge entitlements with the binary.
	var mergeEntitlements: Bool
	/// If the keychain access group should be unique to this app (`TEAMID.<bundle id>`), wildcard profiles only
	var isolateKeychain: Bool
	/// If the bundle ID should automatically be taken from a non-wildcard provisioning profile
	var autoProfileBundleId: Bool

	// MARK: Experiments
	
	/// Modifies app to support liquid glass
	var experiment_supportLiquidGlass: Bool
	/// Modifies app to disable liquid glass
	var experiment_disableLiquidGlass: Bool
	/// Modifies application to use ElleKit instead of CydiaSubstrate
	var experiment_replaceSubstrateWithEllekit: Bool
	
	// MARK: Post Modifications
	
	var post_installAppAfterSigned: Bool
	/// This will delete your imported application after signing, to save on using unneeded space.
	var post_deleteAppAfterSigned: Bool
	/// Deletes the signed copy from the library once it has been installed.
	var post_deleteSignedAfterInstall: Bool
	
	// MARK: - Defaults
	static let defaultOptions = Options(
		
		// MARK: Pre Modifications
		
		appAppearance: .default,
		minimumAppRequirement: .default,
		signingOption: .default,
		
		// MARK: Options
		
		injectPath: .executable_path,
		injectFolder: .frameworks,
		ppqString: randomString(),
		ppqProtection: false,
		dynamicProtection: false,
		identifiers: [:],
		displayNames: [:],
		injectionFiles: [],
		disInjectionFiles: [],
		removeFiles: [],
		fileSharing: false,
		itunesFileSharing: false,
		proMotion: false,
		gameMode: false,
		ipadFullscreen: false,
		removeURLScheme: false,
		removeProvisioning: false,
		removeWatchApp: false,
		changeLanguageFilesForCustomDisplayName: false,
		injectIntoExtensions: false,
		injectIntoWatchApp: false,
		mergeEntitlements: false,
		isolateKeychain: false,
		autoProfileBundleId: false,
		
		// MARK: Experiments
		
		experiment_supportLiquidGlass: false,
		experiment_disableLiquidGlass: false,
		experiment_replaceSubstrateWithEllekit: false,
		
		// MARK: Post Modifications
		
		post_installAppAfterSigned: false,
		post_deleteAppAfterSigned: false,
		post_deleteSignedAfterInstall: false
	)
	
	// MARK: duplicate values are not recommended!

	enum AppAppearance: String, Codable, CaseIterable, LocalizedDescribable {
		case `default`
		case light = "Light"
		case dark = "Dark"

		var localizedDescription: String {
			switch self {
			case .default: .localized("Default")
			case .light: .localized("Light")
			case .dark: .localized("Dark")
			}
		}
	}

	enum MinimumAppRequirement: String, Codable, CaseIterable, LocalizedDescribable {
		case `default`
		case v16 = "16.0"
		case v15 = "15.0"
		case v14 = "14.0"
		case v13 = "13.0"
		case v12 = "12.0"

		var localizedDescription: String {
			switch self {
			case .default: .localized("Default")
			case .v16: "16.0"
			case .v15: "15.0"
			case .v14: "14.0"
			case .v13: "13.0"
			case .v12: "12.0"
			}
		}
	}
	
	enum SigningOption: String, Codable, CaseIterable, LocalizedDescribable {
		case `default`
		case onlyModify
//		case adhoc

		var localizedDescription: String {
			switch self {
			case .default: .localized("Default")
			case .onlyModify: .localized("Modify")
//			case .adhoc: .localized("Ad-hoc")
			}
		}
	}
	
	enum InjectPath: String, Codable, CaseIterable, LocalizedDescribable {
		case executable_path = "@executable_path"
		case rpath = "@rpath"
	}
	
	enum InjectFolder: String, Codable, CaseIterable, LocalizedDescribable {
		case root = "/"
		case frameworks = "/Frameworks/"
	}
	
	/// Default random value for `ppqString`
	static func randomString() -> String {
		String((0..<6).compactMap { _ in UUID().uuidString.randomElement() })
	}
}

// MARK: - LocalizedDescribable

protocol LocalizedDescribable {
	var localizedDescription: String { get }
}

extension LocalizedDescribable where Self: RawRepresentable, RawValue == String {
	var localizedDescription: String {
		let localized = NSLocalizedString(self.rawValue, comment: "")
		return localized == self.rawValue ? self.rawValue : localized
	}
}
