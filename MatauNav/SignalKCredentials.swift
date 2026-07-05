import Foundation
import Security

/// Keychain storage for optional SignalK credentials.
/// Stored with ThisDeviceOnly so they never leave the phone via iCloud Keychain.
/// Accessible after first unlock so reconnect works while the device is locked.
enum SignalKKeychain {
    private static let service  = "com.matau.nav.signalk"
    private static let userKey  = "username"
    private static let passKey  = "password"

    static func save(username: String, password: String) {
        set(account: userKey, value: username)
        set(account: passKey, value: password)
    }

    static func loadCredentials() -> (username: String, password: String)? {
        guard let user = get(account: userKey), !user.isEmpty,
              let pass = get(account: passKey) else { return nil }
        return (user, pass)
    }

    static func clear() {
        delete(account: userKey)
        delete(account: passKey)
    }

    // MARK: - Keychain primitives

    private static func set(account: String, value: String) {
        let data = Data(value.utf8)
        var query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            query[kSecValueData]          = data
            query[kSecAttrAccessible]     = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func get(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  account,
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne,
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
