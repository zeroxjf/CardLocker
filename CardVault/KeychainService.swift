// KeychainService.swift

import Foundation
import Security

/// A simple wrapper around Keychain operations for CardVault.
enum KeychainService {
    private static let service = "CardVault"

    /// Save secure card fields (number, expiry, cvv) to Keychain.
    static func save(_ card: Card) {
        let fields = [
            ("number", card.number ?? ""),
            ("expiry", card.expiry ?? ""),
            ("cvv", card.cvv ?? "")
        ]

        for (key, value) in fields {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "\(card.id.uuidString)_\(key)"
            ]

            // Remove any existing item
            SecItemDelete(query as CFDictionary)

            // Insert the new value
            var attributes = query
            attributes[kSecValueData as String] = value.data(using: .utf8)
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    /// Load secure card fields from Keychain for a given Card.
    static func loadFields(for card: Card) -> Card {
        var updated = card

        func read(_ key: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "\(card.id.uuidString)_\(key)",
                kSecReturnData as String: true
            ]
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
            return nil
        }

        updated.number = read("number")
        updated.expiry = read("expiry")
        updated.cvv = read("cvv")
        return updated
    }

    /// Delete all secure fields for a card from Keychain.
    static func deleteFields(for card: Card) {
        let keys = ["number", "expiry", "cvv"]
        for key in keys {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "\(card.id.uuidString)_\(key)"
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}