import Foundation
import Security

struct CredentialStorageError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { L("無法存取鑰匙圈（代碼 \(status)）。") }
}

struct KeyInputError: LocalizedError {
    var errorDescription: String? { L("API key 格式不正確：不能是空白，也不能含空格或中文。") }
}

/// iOS 鑰匙圈；測試用一次性 UUID service 並在結束時清除。
struct KeychainCredentialStore: Sendable {
    static let defaultService = "com.utuvo.wallpaper.openai"
    let service: String
    init(service: String = KeychainCredentialStore.defaultService) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "openai"]
    }

    func exists() throws -> Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw CredentialStorageError(status: status) }
        return true
    }

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStorageError(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStorageError(status: errSecDecode)
        }
        return value
    }

    static func validate(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }) else { throw KeyInputError() }
        return key
    }

    func save(_ value: String) throws {
        let key = try Self.validate(value)
        let values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStorageError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStorageError(status: status) }
    }
}

/// 讀取順序：鑰匙圈 → 程序環境變數 `OPENAI_API_KEY`（模擬器開發用）。
enum CredentialResolver {
    enum Source: Equatable { case keychain, environment }

    static func resolve(store: KeychainCredentialStore = KeychainCredentialStore(),
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> (key: String, source: Source)? {
        if let key = try? store.read(), !key.isEmpty { return (key, .keychain) }
        if let env = environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return (env, .environment)
        }
        return nil
    }
}
