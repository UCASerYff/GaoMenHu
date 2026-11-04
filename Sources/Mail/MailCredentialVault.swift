import Foundation
import Security

/// The only persistence layer for passwords, app passwords, and OAuth credentials.
enum MailCredentialVault {
    #if DEBUG_TESTING
    private static let service = "com.gaoseries.GaoYouJian.Testing.credentials"
    #else
    private static let service = "com.gaoseries.GaoYouJian.credentials"
    #endif

    static func save(_ value: String, for identifier: String) throws {
        try saveData(Data(value.utf8), for: identifier)
    }

    static func read(_ identifier: String) throws -> String? {
        guard let data = try readData(identifier) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw MailCredentialVaultError.invalidData }
        return value
    }

    static func delete(_ identifier: String) throws {
        let status = SecItemDelete(query(identifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MailCredentialVaultError.status(status) }
    }

    static func saveData(_ data: Data, for identifier: String) throws {
        guard !identifier.isEmpty else { throw MailCredentialVaultError.invalidIdentifier }
        let lookup = query(identifier)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = lookup
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw MailCredentialVaultError.status(added) }
        } else if status != errSecSuccess {
            throw MailCredentialVaultError.status(status)
        }
    }

    /// New-account authorization must never replace another credential, even in a race.
    static func insertData(_ data: Data, for identifier: String) throws {
        guard !identifier.isEmpty else { throw MailCredentialVaultError.invalidIdentifier }
        var insert = query(identifier)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw MailCredentialVaultError.status(status) }
    }

    static func readData(_ identifier: String) throws -> Data? {
        guard !identifier.isEmpty else { throw MailCredentialVaultError.invalidIdentifier }
        var lookup = query(identifier)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MailCredentialVaultError.status(status) }
        guard let data = result as? Data else { throw MailCredentialVaultError.invalidData }
        return data
    }

    private static func query(_ identifier: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: identifier,
         kSecAttrSynchronizable as String: false]
    }
}

enum MailCredentialVaultError: LocalizedError {
    case status(OSStatus), invalidData, invalidIdentifier
    var errorDescription: String? {
        switch self {
        case .status(let code):
            return "无法访问系统钥匙串（\(code)）。请确认已解锁钥匙串，并由本人按系统提示决定是否允许搞门户访问原邮件凭据。"
        case .invalidData: return "钥匙串中的凭据格式不正确，请重新设置此邮箱的凭据。"
        case .invalidIdentifier: return "凭据标识为空，无法保存。"
        }
    }
}
