import Foundation
import Security
import LocalAuthentication

struct CredentialStorageError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { L("無法存取 Mac 鑰匙圈（代碼 \(status)）。請確認鑰匙圈已解鎖。") }
}

/// Queries only this application's item; tests use a separate UUID service.
struct KeychainCredentialStore {
    let service: String
    init(service: String = "com.utuvo.wallpaper-lab.openai") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "openai"]
    }
    private var readQuery: [String: Any] {
        var request = query
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return request
    }

    func exists() throws -> Bool {
        var request = readQuery
        request[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw CredentialStorageError(status: status) }
        return true
    }

    func read() throws -> String? {
        var request = readQuery
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStorageError(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStorageError(status: errSecDecode)
        }
        return value
    }

    func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }) else {
            throw KeyInputError()
        }
        let values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStorageError(status: status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStorageError(status: status) }
    }
}

struct KeyInputError: LocalizedError {
    var errorDescription: String? { L("API key 不能是空白，也不能包含空格或換行。") }
}

/// 憑證只在記憶體裡讀取；使用者在設定頁儲存時使用 Mac 鑰匙圈。
///
/// 規則：
/// - 舊的本機 .env 僅作唯讀相容，不會匯出或複製它。
/// - 只接受單行 `KEY=value`（可選 `export ` 前綴），去掉成對引號。
/// - 絕不 `source` 檔案、絕不 eval、絕不把值寫進日誌或錯誤訊息。
enum CredentialStore {
    static let envFileName = "~/.config/utuvo-wallpaper/openai.env"
    /// 檔案裡依序接受的 key 名稱。
    static let envKeyNames = ["OPENAI_API_KEY", "OPENAI_CREDITS_KEY"]
    static let processEnvKeyName = "OPENAI_API_KEY"

    /// 傳回憑證字串本身（只在記憶體）。找不到回傳 nil。
    static func load() -> String? {
        do {
            if let stored = try KeychainCredentialStore().read() { return stored }
        } catch { return nil } // A locked/denied Keychain must not silently switch accounts.
        // 1) 程序環境變數優先
        if let v = ProcessInfo.processInfo.environment[processEnvKeyName]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            return v
        }
        // 2) 既有 .env 檔案
        guard let text = try? String(contentsOf: envFileURL(), encoding: .utf8) else { return nil }
        let parsed = parse(text)
        return envValue(in: parsed)
    }

    static func sourceDescription() -> String {
        do {
            if try KeychainCredentialStore().exists() { return L("Mac 鑰匙圈") }
        } catch { return L("鑰匙圈目前無法存取") }
        if let value = ProcessInfo.processInfo.environment[processEnvKeyName],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L("環境變數 OPENAI_API_KEY") }
        if let text = try? String(contentsOf: envFileURL(), encoding: .utf8),
           envValue(in: parse(text)) != nil { return L("既有本機 .env（相容模式）") }
        return L("尚未設定")
    }

    static func envValue(in parsed: [String: String]) -> String? {
        envKeyNames.lazy.compactMap { parsed[$0] }.first { !$0.isEmpty }
    }

    static func envFileURL() -> URL {
        URL(fileURLWithPath: NSString(string: envFileName).expandingTildeInPath)
    }

    /// 安全的單行 KEY=value 解析器。
    /// - 不執行任何 shell 語法；`export` 前綴只是被剝掉而已。
    /// - 忽略空行、`#` 註解與沒有 `=` 的行。
    /// - 只保留合法的識別字型 key。
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }

            var key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") {
                key = String(key.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard isValidKey(key) else { continue }

            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 {
                let first = value.first!
                let last = value.last!
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            result[key] = value
        }
        return result
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
