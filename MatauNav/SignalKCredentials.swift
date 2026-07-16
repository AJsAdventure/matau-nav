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
        Keychain.set(service: service, account: userKey, value: username)
        Keychain.set(service: service, account: passKey, value: password)
    }

    static func loadCredentials() -> (username: String, password: String)? {
        guard let user = Keychain.get(service: service, account: userKey), !user.isEmpty,
              let pass = Keychain.get(service: service, account: passKey) else { return nil }
        return (user, pass)
    }

    static func clear() {
        Keychain.delete(service: service, account: userKey)
        Keychain.delete(service: service, account: passKey)
    }
}

/// Cloudflare Access service-token secret for the public HTTPS remote bridge
/// (the matau-<port>.<domain> hostnames). The client ID lives in AppSettings;
/// only the secret is Keychain material.
enum CFAccessKeychain {
    private static let service   = "com.matau.nav.cfaccess"
    private static let secretKey = "client-secret"

    static func save(secret: String) {
        Keychain.set(service: service, account: secretKey, value: secret)
    }

    static func loadSecret() -> String? {
        Keychain.get(service: service, account: secretKey)
    }

    static func clear() {
        Keychain.delete(service: service, account: secretKey)
    }
}

// MARK: - Keychain primitives (shared)

fileprivate enum Keychain {

    static func set(service: String, account: String, value: String) {
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

    static func get(service: String, account: String) -> String? {
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

    static func delete(service: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
