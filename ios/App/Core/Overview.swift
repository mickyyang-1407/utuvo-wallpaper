import Foundation

/// Overview 的真實數字（不加假資料）。
struct CategorySegment: Equatable, Identifiable {
    let category: String
    let newCount: Int
    let oldCount: Int
    var total: Int { newCount + oldCount }
    var id: String { category }
}

enum OverviewFacts {
    /// 依分類順序統計；今天修改的生成圖算「新的」，示範圖與較舊的算「之前的」。
    static func segments(items: [WallpaperItem], now: Date, calendar: Calendar = .current) -> [CategorySegment] {
        WallpaperCategory.order.compactMap { category in
            let inCategory = items.filter { $0.category == category }
            let new = inCategory.filter { !$0.isDemo && calendar.isDate($0.modified, inSameDayAs: now) }.count
            let seg = CategorySegment(category: category, newCount: new, oldCount: inCategory.count - new)
            return seg.total > 0 ? seg : nil
        }
    }

    static func todayNew(items: [WallpaperItem], now: Date, calendar: Calendar = .current) -> Int {
        items.filter { !$0.isDemo && calendar.isDate($0.modified, inSameDayAs: now) }.count
    }

    /// 下一個時段與切換時間。
    static func nextPhase(after date: Date, calendar: Calendar = .current) -> (phase: DayPhase, time: String) {
        let hour = calendar.component(.hour, from: date)
        switch DayPhase.current(hour: hour) {
        case .dawn: return (.day, DayPhase.day.time)
        case .day: return (.dusk, DayPhase.dusk.time)
        case .dusk: return (.night, DayPhase.night.time)
        case .night: return (.dawn, DayPhase.dawn.time)
        }
    }
}
