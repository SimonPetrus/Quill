//
//  KeychainHelper.swift
//  Quill
//
//  Stores certificate passwords as generic-password Keychain items.
//  service = fixed constant, account = certificate uuid. Values are never logged.
//

import Foundation
import Security
import OSLog

enum KeychainHelper {
	/// Fixed on purpose (not derived from the bundle id) so items survive any bundle changes.
	static let service = "app.quill.sign.certificate"

	/// AfterFirstUnlock (not WhenUnlocked): signing keeps running while the device is locked
	/// (background audio keeps the app alive), and a WhenUnlocked item would then be unreadable
	/// and make signing fail with a wrong-password error. Still this-device-only, never synced.
	private static let _accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

	private static func _query(_ account: String?) -> [String: Any] {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service
		]
		if let account { query[kSecAttrAccount as String] = account }
		return query
	}

	/// Creates or replaces the item. Returns false on failure (logged without the value).
	@discardableResult
	static func set(_ value: String, for account: String) -> Bool {
		let data = Data(value.utf8)
		var attributes: [String: Any] = [kSecValueData as String: data]
		let status = SecItemUpdate(_query(account) as CFDictionary, attributes as CFDictionary)
		if status == errSecSuccess { return true }
		guard status == errSecItemNotFound else {
			Logger.misc.error("Keychain update failed (\(status))")
			return false
		}
		attributes = _query(account)
		attributes[kSecValueData as String] = data
		attributes[kSecAttrAccessible as String] = _accessible
		let addStatus = SecItemAdd(attributes as CFDictionary, nil)
		if addStatus != errSecSuccess {
			Logger.misc.error("Keychain add failed (\(addStatus))")
			return false
		}
		return true
	}

	static func get(_ account: String) -> String? {
		var query = _query(account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecSuccess, let data = result as? Data {
			return String(data: data, encoding: .utf8)
		}
		if status != errSecItemNotFound {
			Logger.misc.error("Keychain read failed (\(status))")
		}
		return nil
	}

	@discardableResult
	static func delete(_ account: String) -> Bool {
		let status = SecItemDelete(_query(account) as CFDictionary)
		if status != errSecSuccess && status != errSecItemNotFound {
			Logger.misc.error("Keychain delete failed (\(status))")
			return false
		}
		return true
	}

	/// Removes every certificate password item of this app.
	@discardableResult
	static func deleteAll() -> Bool {
		let status = SecItemDelete(_query(nil) as CFDictionary)
		if status != errSecSuccess && status != errSecItemNotFound {
			Logger.misc.error("Keychain delete-all failed (\(status))")
			return false
		}
		return true
	}
}
