import Foundation

/// 設定都從這裡讀寫（Mac 與 iPhone 共用）。
/// Mac 的背景助手（bundle id 結尾 `.agent`）讀寫主 App 的設定網域，不另存一份；
/// 其他情況就是 `.standard`。
enum AppDefaults {
    static let agentSuffix = ".agent"

    /// 主 App 的設定網域名稱；不是助手時回 nil。
    static func hostDomain(for bundleIdentifier: String?) -> String? {
        guard let id = bundleIdentifier, id.hasSuffix(agentSuffix), id.count > agentSuffix.count else { return nil }
        return String(id.dropLast(agentSuffix.count))
    }

    static let shared: UserDefaults = {
        if let host = hostDomain(for: Bundle.main.bundleIdentifier), let defaults = UserDefaults(suiteName: host) {
            return defaults
        }
        return .standard
    }()

    /// 助手啟動時呼叫：介面語言跟主 App 的選擇（語言查表讀的是本程序自己的 AppleLanguages）。
    static func adoptHostLanguage() {
        guard let host = hostDomain(for: Bundle.main.bundleIdentifier) else { return }
        let languages = UserDefaults.standard.persistentDomain(forName: host)?["AppleLanguages"]
        if let languages { UserDefaults.standard.set(languages, forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
    }
}
