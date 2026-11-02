import Foundation

/// App 內的介面語言選擇（Mac 與 iPhone 共用）。
/// 寫入本 App 自己的 `AppleLanguages`，下次啟動生效；不動系統語言。
/// Mac 背景助手啟動時沿用主 App 的 AppleLanguages（AppDefaults.adoptHostLanguage），狀態文字跟著同一個選擇。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }

    /// 語言名稱用該語言本身書寫，選錯語言時也認得出來。
    var displayName: String {
        switch self {
        case .system: return L("跟隨系統")
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }

    static let defaultsKey = "AppleLanguages"
    /// 自己另存一份選擇：iOS 的 App 容器讀不到 persistentDomain，而 AppleLanguages 讀不到時會落到系統全域值。
    static let choiceKey = "UTUVOAppLanguage"

    static func current(defaults: UserDefaults = AppDefaults.shared) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: choiceKey) ?? "") ?? .system
    }

    static func from(languageCode code: String) -> AppLanguage {
        if code.hasPrefix("zh") { return .traditionalChinese }
        if code.hasPrefix("en") { return .english }
        return .system
    }

    static func apply(_ language: AppLanguage, defaults: UserDefaults = AppDefaults.shared) {
        switch language {
        case .system:
            defaults.removeObject(forKey: defaultsKey)
            defaults.removeObject(forKey: choiceKey)
        default:
            defaults.set([language.rawValue], forKey: defaultsKey)
            defaults.set(language.rawValue, forKey: choiceKey)
        }
        defaults.synchronize()
    }

    /// 啟動當下的選擇；進入點要先讀一次，之後的變更都要重開才生效。
    static let atLaunch = current()

    static func needsRelaunch(selected: AppLanguage) -> Bool { selected != atLaunch }
}
