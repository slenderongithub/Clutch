import Foundation
import Security

/// The Gemini API key, kept in the macOS Keychain rather
/// than the preferences plist (which any process running as the user can
/// read in plain text). Values found in UserDefaults from older builds are
/// moved into the Keychain and deleted from UserDefaults on first launch.
@Observable
@MainActor
final class Secrets {
    static let shared = Secrets()

    var geminiAPIKey: String {
        didSet { Keychain.set(geminiAPIKey, account: "geminiAPIKey") }
    }

    private init() {
        geminiAPIKey = Self.load("geminiAPIKey")
        // The Neo4j era is over: drop its stored password.
        Keychain.set("", account: "neo4jPassword")
        for key in ["neo4jPassword", "neo4jURI", "neo4jUser"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private static func load(_ account: String) -> String {
        if let stored = Keychain.get(account) { return stored }
        guard let legacy = UserDefaults.standard.string(forKey: account) else { return "" }
        Keychain.set(legacy, account: account)
        UserDefaults.standard.removeObject(forKey: account)
        return legacy
    }
}

private enum Keychain {
    private static let service = "com.clutch.app"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let query = query(account)
        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
