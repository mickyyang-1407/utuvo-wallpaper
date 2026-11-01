import Foundation

/// 介面字串以繁中原文為 key（與 Mac 版相同），英文在 `en.lproj/Localizable.strings`。
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value)
}
