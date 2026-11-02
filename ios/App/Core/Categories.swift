import Foundation

/// 分類規則與 Mac `WallpaperLibrary.category(forFileName:)` 相同：檔名前綴＝範本 id。
enum WallpaperCategory {
    static let other = "其他"
    private static let legacy = ["alpine-dawn": "自然", "paper-landscape": "極簡"]

    static func category(forFileName name: String) -> String {
        let lowered = name.lowercased()
        let matches = PromptTemplate.shared.map { ($0.id, $0.category) } + legacy.map { ($0.key, $0.value) }
        return matches.filter { lowered == $0.0 || lowered.hasPrefix($0.0 + "-") || lowered.hasPrefix($0.0 + ".") }
            .max { $0.0.count < $1.0.count }?.1 ?? other
    }

    /// 範本出現順序，「其他」放最後。
    static var order: [String] {
        var seen = Set<String>()
        return PromptTemplate.shared.map(\.category).filter { seen.insert($0).inserted } + [other]
    }

    /// 分類名稱（中文 key）的顯示字串。
    static func title(_ category: String) -> String {
        switch category {
        case "自然": return L("自然")
        case "極簡": return L("極簡")
        case "抽象": return L("抽象")
        case "插畫": return L("插畫")
        case "宇宙": return L("宇宙")
        case "水彩": return L("水彩")
        case "建築": return L("建築")
        case "動畫": return L("動畫")
        case "純色": return L("純色")
        case "漸層": return L("漸層")
        case "深色": return L("深色")
        case "幾何": return L("幾何")
        case "城市": return L("城市")
        case "動物": return L("動物")
        case "3D": return L("3D")
        default: return L("其他")
        }
    }
}

/// 圖庫頂部的篩選。
enum GalleryFilter: Hashable, Identifiable {
    case all, favorites, category(String)
    var id: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .category(let name): return "c-" + name
        }
    }
    var title: String {
        switch self {
        case .all: return L("全部")
        case .favorites: return L("收藏")
        case .category(let name): return WallpaperCategory.title(name)
        }
    }
    static var allFilters: [GalleryFilter] { [.all, .favorites] + WallpaperCategory.order.map { .category($0) } }
}
