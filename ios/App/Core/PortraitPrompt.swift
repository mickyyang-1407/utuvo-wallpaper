import Foundation

/// 共用的 `PromptTemplate.shared` 是橫式 16:9 桌面桌布；iPhone 送出前轉成直式。
enum PortraitPrompt {
    static let clockSentence = "vertical 9:16 iPhone wallpaper, keep the main subject in the middle and lower two thirds so the clock area at the top stays calm"

    private static let rules: [(pattern: String, replacement: String)] = [
        (#"vertical texture yet wide 16:9 framing"#, "vertical framing"),
        (#"wide\s+16:9\s+desktop\s+wallpaper"#, "vertical 9:16 iPhone wallpaper"),
        (#"16:9\s+desktop\s+wallpaper"#, "vertical 9:16 iPhone wallpaper"),
        (#"wide\s+16:9"#, "vertical 9:16"),
        (#"16\s*:\s*9"#, "9:16"),
        (#"desktop\s+wallpaper"#, "iPhone wallpaper"),
        (#"desktop\s+landscape"#, "phone landscape"),
        (#"calm horizontal rhythm"#, "calm layered rhythm")
    ]

    /// 純函式：把橫式字樣換成直式，並補上時鐘區留白的說明。
    static func convert(_ prompt: String) -> String {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        for rule in rules {
            text = text.replacingOccurrences(of: rule.pattern, with: rule.replacement,
                                             options: [.regularExpression, .caseInsensitive])
        }
        if text.hasSuffix(".") { text.removeLast() }
        return text + ", " + clockSentence + "."
    }
}
