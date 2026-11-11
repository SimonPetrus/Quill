//
//  OwnSigningIdentity.swift
//  Quill
//
//  Compares Quill's own bundle ID with the App ID of the profile it is signed with.
//

import Foundation

/// The bundle ID Quill ships with in its release IPA. Used to recognise Quill's own IPA even when
/// the installed copy runs under another bundle ID (e.g. re-signed with the profile's App ID).
let quillCanonicalBundleID = "app.quill.sign"

/// When Quill is signed with a profile for a different, fixed App ID (e.g. `TEAMID.simon.bjk`)
/// while keeping `app.quill.sign`, iOS does not hand shared files to the app (the scene connects
/// without URL contexts). Read once from the app's own `embedded.mobileprovision`.
enum OwnSigningIdentity {
	enum State: Equatable {
		/// App ID and bundle ID agree.
		case match
		/// Wildcard profile (`TEAMID.*` or `TEAMID.prefix.*`): no warning.
		case wildcard
		/// Fixed App ID that differs from the bundle ID; `profileBundleID` is the ID without team prefix.
		case mismatch(profileBundleID: String)
		/// No profile (simulator, profile removed while signing) or unreadable: stay silent.
		case unknown
	}

	static let current: State = {
		let state = _evaluate()
		let name: String
		switch state {
		case .match: name = "match"
		case .wildcard: name = "wildcard"
		case .mismatch: name = "mismatch"
		case .unknown: name = "noProfile"
		}
		// The IDs themselves are not logged (they can contain personal names).
		IncomingLog.notice("Signing identity: state=\(name)")
		return state
	}()

	/// The profile's App ID (without team prefix) when it is fixed and differs from the bundle ID.
	static var mismatchedProfileBundleID: String? {
		if case .mismatch(let id) = current { return id }
		return nil
	}

	private static func _evaluate() -> State {
		guard
			let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
			let profile = CertificateReader(url).decoded,
			let full = profile.applicationIdentifier,
			let bundleID = Bundle.main.bundleIdentifier
		else { return .unknown }

		guard !full.contains("*") else { return .wildcard }
		guard let profileBundleID = profile.fixedAppIDBundleID else { return .unknown }
		return sameBundleID(profileBundleID, bundleID) ? .match : .mismatch(profileBundleID: profileBundleID)
	}
}

// MARK: - Profile App ID (shared with SigningView)
extension Certificate {
	/// The `application-identifier` entitlement, e.g. "TEAMID.com.example.app" or "TEAMID.*".
	var applicationIdentifier: String? {
		Entitlements?["application-identifier"]?.value as? String
	}

	/// The App ID without its team prefix; nil for wildcard or unreadable App IDs.
	var fixedAppIDBundleID: String? {
		guard let full = applicationIdentifier, !full.contains("*") else { return nil }
		let prefix = ApplicationIdentifierPrefix?.first ?? TeamIdentifier.first
		var id = full
		if let prefix, full.hasPrefix(prefix + ".") {
			id = String(full.dropFirst(prefix.count + 1))
		} else if let dot = full.firstIndex(of: ".") {
			id = String(full[full.index(after: dot)...])
		}
		return id.isEmpty ? nil : id
	}
}
