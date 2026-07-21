//  KeychainStore.swift
//  AICam — 簡易 Keychain 字串儲存（kSecClassGenericPassword）。
//
//  service 固定 "com.arieswu.aicam"；一個 key 對應一個 generic password 項目。
//  set = 先 SecItemDelete 再 SecItemAdd，避免 errSecDuplicateItem。

import Foundation
import Security

enum KeychainStore {

    private static let service = "com.arieswu.aicam"

    /// 讀取字串；項目不存在或解碼失敗回 nil。
    static func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 寫入字串（先刪除舊項目再新增）。
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(forKey: key)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// 刪除項目；項目本來就不存在也視為成功。
    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
