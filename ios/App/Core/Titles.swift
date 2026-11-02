import Foundation

/// 顯示名稱（比照 macOS）：只影響顯示，不改檔名或資料。
/// - 早期示範檔：只有完全相同的檔名才用固定名稱。
/// - 範本生成：「範本標題 · 日期」；同範本同日重複時再加「 · 1／· 2」。
enum WallpaperTitles {
    /// 範本 id → 顯示名稱。字面常數讓 check.py 抽得到 key。
    static func templateTitle(_ id: String) -> String? {
        switch id {
        case "nature-dawn": return L("自然風景")
        case "minimal-paper": return L("紙雕極簡")
        case "abstract-flow": return L("流動光帶")
        case "illustration-dusk": return L("插畫街景")
        case "cosmic-nebula": return L("深空")
        case "botanical-macro": return L("自然微距")
        case "watercolor-meadow": return L("水彩風景")
        case "architecture-arcade": return L("建築光影")
        case "animation-coast": return L("手繪動畫")
        case "gradient-tide": return L("柔和漸層")
        case "solid-color": return L("純色")
        case "gradient-soft": return L("漸層")
        case "dark-oled": return L("深色")
        case "geometric": return L("幾何")
        case "city": return L("城市")
        case "animals": return L("動物")
        case "render-3d": return L("3D 立體")
        default: return nil
        }
    }

    static func legacyTitle(_ fileName: String) -> String? {
        switch fileName.lowercased() {
        case "abstract-flow-5k.png": return L("流光")
        case "alpine-dawn-5k.png": return L("湖畔晨光")
        case "paper-landscape-5k.png", "paper-landscape-demo-5k.jpg": return L("紙上山丘")
        default: return nil
        }
    }

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 中文 M/d；英文 “Nov 1”。
    static func dayFormatter(language: String = Bundle.main.preferredLocalizations.first ?? "en") -> DateFormatter {
        let formatter = DateFormatter()
        if language.hasPrefix("zh") {
            formatter.dateFormat = "M/d"
        } else {
            formatter.locale = Locale(identifier: "en_US")
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter
    }

    static func fileName(_ item: WallpaperItem) -> String { item.isDemo ? String(item.id.dropFirst(5)) : item.id }

    static func baseTitle(_ item: WallpaperItem, formatter: DateFormatter) -> String {
        let name = fileName(item)
        if let legacy = legacyTitle(name) { return legacy }
        let lowered = name.lowercased()
        guard let template = PromptTemplate.shared.map(\.id)
            .filter({ lowered.hasPrefix($0 + "-") || lowered.hasPrefix($0 + ".") })
            .max(by: { $0.count < $1.count }),
              let title = templateTitle(template) else {
            return (name as NSString).deletingPathExtension
        }
        return "\(title) · \(formatter.string(from: day(of: item, lowered: lowered)))"
    }

    private static func day(of item: WallpaperItem, lowered: String) -> Date {
        if let range = lowered.range(of: #"daily-\d{4}-\d{2}-\d{2}"#, options: .regularExpression),
           let date = dayParser.date(from: String(lowered[range].dropFirst("daily-".count))) {
            return date
        }
        return item.modified
    }

    /// 一次算整個圖庫的名稱（重複者依檔名排序編號）。
    static func titles(for items: [WallpaperItem], formatter: DateFormatter = dayFormatter()) -> [String: String] {
        let bases = items.sorted { $0.id < $1.id }.map { ($0.id, baseTitle($0, formatter: formatter)) }
        let totals = Dictionary(grouping: bases, by: { $0.1 }).mapValues(\.count)
        var seen: [String: Int] = [:]
        var result: [String: String] = [:]
        for (id, base) in bases {
            guard totals[base, default: 0] > 1 else { result[id] = base; continue }
            let index = seen[base, default: 0] + 1
            seen[base] = index
            result[id] = "\(base) · \(index)"
        }
        return result
    }
}
