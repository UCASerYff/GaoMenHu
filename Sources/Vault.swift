import Foundation
import Security
import LocalAuthentication

final class Vault {
    private let service = "cn.mendao.launcher.passwords"
    private var authenticatedUntil = Date.distantPast
    private var memory: [String: String] = [:]
    let testing: Bool
    init(testing: Bool = false) { self.testing = testing }
    var unlocked: Bool { testing || authenticatedUntil > Date() }
    func lock() { authenticatedUntil = .distantPast }
    func authenticate(_ reason: String, completion: @escaping (Bool, String?) -> Void) {
        if unlocked { completion(true, nil); return }
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false, "无法验证 Mac 身份。请先为系统账号设置密码或 Touch ID。")
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                if success { self.authenticatedUntil = Date().addingTimeInterval(300) }
                completion(success, success ? nil : "已取消解锁。")
            }
        }
    }
    func save(_ password: String, id: String) throws {
        if testing { memory[id] = password; return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: id]
        let changes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let update = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AppError.message("保存到钥匙串失败（\(update)）。") }
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "搞门户 · 网站账号"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppError.message("保存到钥匙串失败（\(status)）。") }
    }
    func read(id: String) throws -> String {
        guard unlocked else { throw AppError.message("请先解锁账号库。") }
        if testing { return memory[id] ?? "" }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: id,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw AppError.message("该账号的密码不在钥匙串中，请重新保存。") }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw AppError.message("读取钥匙串失败（\(status)）。")
        }
        return text
    }
    func remove(id: String) throws {
        if testing { memory.removeValue(forKey: id); return }
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: id] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message("删除钥匙串密码失败（\(status)）。") }
    }
}
