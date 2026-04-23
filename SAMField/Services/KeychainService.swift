//
//  KeychainService.swift
//  SAM Field
//
//  Lightweight Keychain wrapper for SAMField. Storage is bound to the
//  device (kSecAttrAccessibleWhenUnlockedThisDeviceOnly) so the pairing
//  token doesn't follow the user across devices via iCloud backup.
//

import Foundation
import Security
import os.log

actor KeychainService {

    static let shared = KeychainService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "KeychainService")

    private let service = "com.matthewsessions.SAMField"

    // MARK: - Data

    func storeData(_ data: Data, forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]

        var status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        guard status == errSecSuccess else {
            logger.error("Failed to store keychain item for key '\(key)': \(status)")
            throw KeychainError.unhandledError(status: status)
        }
    }

    func retrieveData(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                logger.error("Failed to retrieve keychain item for key '\(key)': \(status)")
            }
            return nil
        }
        return data
    }

    // MARK: - String

    func storeString(_ string: String, forKey key: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try storeData(data, forKey: key)
    }

    func retrieveString(forKey key: String) -> String? {
        guard let data = retrieveData(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Delete

    func deleteItem(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Failed to delete keychain item for key '\(key)': \(status)")
            throw KeychainError.unhandledError(status: status)
        }
    }
}

extension KeychainService {
    enum KeychainError: Error, LocalizedError {
        case encodingFailed
        case unhandledError(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed: "Failed to encode string as UTF-8 data"
            case .unhandledError(let status): "Keychain error: \(status)"
            }
        }
    }
}
