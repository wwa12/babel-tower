import Foundation
import Security

/// API Key 存取协议：实现只允许落到系统钥匙串，不进 UserDefaults、日志或仓库。
/// 测试用内存替身，避免碰真实钥匙串。
protocol APIKeyStore: AnyObject {
    func saveAPIKey(_ key: String, forAccount account: String) throws
    func loadAPIKey(forAccount account: String) throws -> String?
    func deleteAPIKey(forAccount account: String) throws
}

enum KeychainStoreError: Error {
    case unexpectedStatus(OSStatus)
    /// 条目存在但内容不是合法 UTF-8 文本（钥匙串条目损坏）
    case corruptedItem
}

/// 系统钥匙串实现（kSecClassGenericPassword，Security 框架，不引第三方）。
/// 不加访问控制属性：同进程读写自身创建的条目不触发授权弹窗，也不需要任何 entitlement。
final class KeychainStore: APIKeyStore {

    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.wwa12.babeltower") {
        self.service = service
    }

    func saveAPIKey(_ key: String, forAccount account: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 先改后加：多数场景是更新已存的 Key
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // 只在本机可用、解锁后即可读：显式声明，不依赖系统默认（Key 保存在本机）
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // 并发写入的窄竞态兜底：回退一次更新
                let retryStatus = SecItemUpdate(query as CFDictionary,
                                                [kSecValueData as String: data] as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw KeychainStoreError.unexpectedStatus(retryStatus)
                }
            } else if addStatus != errSecSuccess {
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func loadAPIKey(forAccount account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.corruptedItem
        }
        return key
    }

    func deleteAPIKey(forAccount account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // 条目本就不存在视为删除成功，调用方无需区分
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }
}
