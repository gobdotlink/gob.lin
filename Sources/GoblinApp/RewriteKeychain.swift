import Foundation
import GoblinCore
import Security

enum RewriteKeychain {
    private static let service = GoblinMetadata.bundleIdentifier + ".rewrite"

    static func load(for settings: RewriteSettings) throws -> String {
        var query = try query(for: settings)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw KeychainFailure(status) }
        return key
    }

    static func containsKey(for settings: RewriteSettings) throws -> Bool {
        let status = SecItemCopyMatching(try query(for: settings) as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainFailure(status) }
        return true
    }

    static func save(_ key: String, for settings: RewriteSettings) throws {
        let query = try query(for: settings)
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainFailure(added) }
        } else if status != errSecSuccess { throw KeychainFailure(status) }
    }

    static func delete(for settings: RewriteSettings) throws {
        let status = SecItemDelete(try query(for: settings) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status) }
    }

    private static func query(for settings: RewriteSettings) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: try settings.endpoint().absoluteString]
    }

    private struct KeychainFailure: LocalizedError {
        let status: OSStatus
        init(_ status: OSStatus) { self.status = status }
        var errorDescription: String? {
            "Keychain could not access the provider credential (\(status)). " + (SecCopyErrorMessageString(status, nil) as String? ?? "Try again after unlocking your Mac.")
        }
    }
}
