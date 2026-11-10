//
//  ErrorExplainer.swift
//  Quill
//
//  Turns raw error text/codes into a short explanation plus a suggested fix.
//  Presentation only: it never changes how an error is produced or handled.
//

import Foundation

enum ErrorExplainer {
	struct Explanation {
		let summary: String
		let suggestion: String
	}
	
	/// Known failure -> (summary key, suggestion key). Both are localized (en/tr in Localizable.xcstrings).
	private struct Rule {
		let summary: String
		let suggestion: String
		/// Lowercased substrings of the raw error text.
		let needles: [String]
		/// `NSError` (domain, code) pairs.
		let codes: [(String, Int)]
		/// Regular expressions (case insensitive), used for numeric codes so "-7001" does not match "-70012".
		let patterns: [String]
		
		init(_ summary: String, _ suggestion: String, needles: [String] = [], patterns: [String] = [], codes: [(String, Int)] = []) {
			self.summary = summary
			self.suggestion = suggestion
			self.needles = needles
			self.patterns = patterns
			self.codes = codes
		}
	}
	
	// Order matters: the first match wins, so specific rules come before generic ones.
	private static let rules: [Rule] = [
		Rule(
			"The device rejected the app signature (ApplicationVerificationFailed, 0xe8008001).",
			"The certificate may be revoked or expired, or the profile does not include this device. Sign again with a valid certificate and profile, then reinstall.",
			needles: ["0xe8008001", "e8008001", "applicationverificationfailed", "application verification failed"]
		),
		Rule(
			"The device connection was lost (RSD error -7001).",
			"Check that the VPN/tunnel app is running and the pairing file is valid, then reconnect and try again.",
			needles: ["remote service discovery", "rsd error"],
			patterns: ["(?<![0-9])-7001(?![0-9])"]
		),
		Rule(
			"There is not enough free storage on the device.",
			"Free up some space (delete old signed or unsigned apps in Quill, or other data) and try again.",
			needles: ["no space left", "not enough space", "out of space", "disk full", "insufficient storage"],
			codes: [("NSCocoaErrorDomain", 640), ("NSPOSIXErrorDomain", 28)]
		),
		Rule(
			"The certificate and provisioning profile do not belong together.",
			"Select a certificate whose .p12 and .mobileprovision were issued as a pair, or import the pair again.",
			needles: ["can't find paired certificate", "cant find paired certificate", "paired certificate"]
		),
		Rule(
			"The certificate password is wrong.",
			"Check the .p12 password (it is case sensitive) and try again.",
			needles: ["mac verify error", "wrong password", "bad password", "incorrect password", "invalid password", "pkcs12 password", "p12 password"]
		),
		Rule(
			"The provisioning profile does not match this app or device.",
			"Use a profile that includes this device and allows the app's bundle ID, or change the bundle ID in the signing options. Also check that the profile has not expired.",
			needles: ["provisioning profile", "no matching profile", "profile has expired", "profile doesn't include", "profile does not include"]
		),
		Rule(
			"A secure connection (SSL) could not be established.",
			"Check the date and time on the device, and that the Local CA is installed and trusted if you use the Fully Local server mode. Try another network if the problem continues.",
			needles: ["ssl", "tls error", "tls handshake", "secure connection", "certificate for this server is invalid", "certificate is not trusted"],
			codes: [("NSURLErrorDomain", -1200), ("NSURLErrorDomain", -1201), ("NSURLErrorDomain", -1202), ("NSURLErrorDomain", -1203), ("NSURLErrorDomain", -1204), ("NSURLErrorDomain", -1205), ("NSURLErrorDomain", -1206)]
		),
		Rule(
			"Could not connect to the server.",
			"Check your internet connection and that the address is correct. For installation, make sure Quill stays open and the install server settings are valid.",
			needles: ["could not connect to the server", "cannot connect", "connection refused", "connection was lost", "timed out", "not connected to the internet", "internet connection appears to be offline"],
			codes: [("NSURLErrorDomain", -1004), ("NSURLErrorDomain", -1001), ("NSURLErrorDomain", -1005), ("NSURLErrorDomain", -1009)]
		),
		Rule(
			"Signing failed.",
			"Check that the certificate is valid (not expired or revoked), matches its profile, and that the app is not corrupted.",
			needles: ["signing failed"]
		)
	]
	
	static func explanation(for error: Error) -> Explanation? {
		let ns = error as NSError
		return explanation(raw: "\(error.localizedDescription) \(ns.domain) \(ns.code) \(String(describing: error))", domain: ns.domain, code: ns.code)
	}
	
	static func explanation(for text: String) -> Explanation? {
		explanation(raw: text, domain: "", code: 0)
	}
	
	private static func explanation(raw: String, domain: String, code: Int) -> Explanation? {
		let haystack = raw.lowercased()
		for rule in rules {
			let byCode = rule.codes.contains { $0.0 == domain && $0.1 == code }
			let byPattern = rule.patterns.contains { haystack.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
			if byCode || byPattern || rule.needles.contains(where: { haystack.contains($0) }) {
				return Explanation(summary: .localized(rule.summary), suggestion: .localized(rule.suggestion))
			}
		}
		return nil
	}
	
	/// "Explanation + suggestion + (Details: raw error)". Unknown errors are returned unchanged.
	static func message(for error: Error) -> String {
		compose(explanation(for: error), raw: error.localizedDescription)
	}
	
	static func message(forText text: String) -> String {
		compose(explanation(for: text), raw: text)
	}
	
	private static func compose(_ explanation: Explanation?, raw: String) -> String {
		guard let explanation else { return raw }
		return "\(explanation.summary)\n\n\(explanation.suggestion)\n\n" + .localized("(Details: %@)", arguments: raw)
	}
}
