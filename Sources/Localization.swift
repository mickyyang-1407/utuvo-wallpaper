import Foundation

/// 介面字串以繁中原文為 key，英文在 `en.lproj/Localizable.strings`。
/// CLI 與自我測試固定輸出繁中原文，不受系統語言影響。
enum Localization {
    nonisolated(unsafe) static var sourceOnly = false
}

/// 查表；找不到（或 sourceOnly）時回傳插值後的繁中原文。
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, table: Localization.sourceOnly ? "SourceOnly" : nil)
}
