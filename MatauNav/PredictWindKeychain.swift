import Foundation
import Security

/// Keychain storage for PredictWind credentials.
/// Stored ThisDeviceOnly so they never leave via iCloud Keychain.
enum PredictWindKeychain {
    private static let service  = "com.matau.nav.predictwind"
    private static let emailKey = "email"
    private static let passKey  = "password"

    static func save(email: String, password: String) {
        set(account: emailKey, value: email)
        set(account: passKey,  value: password)
    }

    static func load() -> (email: String, password: String)? {
        guard let email = get(account: emailKey), !email.isEmpty,
              let pass  = get(account: passKey) else { return nil }
        return (email, pass)
    }

    static func clear() {
        delete(account: emailKey)
        delete(account: passKey)
    }

    // MARK: - Keychain primitives

    private static func set(account: String, value: String) {
        let data = Data(value.utf8)
        var query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData]      = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func get(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str  = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private static func delete(account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
