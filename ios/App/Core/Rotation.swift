import Foundation

/// 輪換游標（持久化）：每次「取得目前桌布」若已換了一個小時就前進一格；同一小時重複呼叫回傳同一張。
struct RotationState: Equatable, Sendable {
    var cursor: Int = 0
    var lastServedSlot: Int?
}

/// 「取得目前桌布」多久換一張。每次執行＝捷徑每跑一次就換下一張。
enum RotationFrequency: String, CaseIterable, Identifiable, Sendable {
    case everyRun, fifteenMinutes, thirtyMinutes, hourly, daily
    var id: String { rawValue }
    var title: String {
        switch self {
        case .everyRun: return L("每次執行都換")
        case .fifteenMinutes: return L("每 15 分鐘")
        case .thirtyMinutes: return L("每 30 分鐘")
        case .hourly: return L("每小時")
        case .daily: return L("每天")
        }
    }
    /// 一格幾分鐘；everyRun 沒有時間格。
    var minutes: Int? {
        switch self {
        case .everyRun: return nil
        case .fifteenMinutes: return 15
        case .thirtyMinutes: return 30
        case .hourly: return 60
        case .daily: return 1440
        }
    }
}

/// 「目前桌布」選擇規則（App Intent 用；純函式、不連網、不生圖）。
enum WallpaperSelection {
    /// 當地「小時序號」：自 2001-01-01 起的日數 × 24 ＋ 小時（單調遞增，跨午夜、跨月都連續）。
    static func hourSlot(year: Int, month: Int, day: Int, hour: Int) -> Int? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let date = utc.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let dayNumber = Int((date.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
        return dayNumber * 24 + hour
    }

    static func hourSlot(at date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return hourSlot(year: c.year ?? 2001, month: c.month ?? 1, day: c.day ?? 1, hour: c.hour ?? 0) ?? 0
    }

    /// 依頻率的時間格序號（當地時間，單調遞增）。everyRun 回 nil。
    static func slot(at date: Date, frequency: RotationFrequency, calendar: Calendar = .current) -> Int? {
        guard let size = frequency.minutes else { return nil }
        let minute = calendar.component(.minute, from: date)
        let minutesSinceRef = hourSlot(at: date, calendar: calendar) * 60 + minute
        return minutesSinceRef / size
    }

    /// 純函式：輸入上次狀態、這次的小時序號與張數 → 新狀態與索引。
    /// - force：「下一張」強制前進一格。
    /// - 非 force：小時序號和上次不同才前進；第一次呼叫只記錄、不前進。
    /// - delta：force 時前進（+1）或後退（−1）。
    static func step(_ state: RotationState, slot: Int, count: Int, force: Bool, delta: Int = 1) -> (state: RotationState, index: Int?) {
        var next = state
        if force {
            next.cursor += delta
        } else if let last = state.lastServedSlot, last != slot {
            next.cursor += 1
        }
        next.lastServedSlot = slot
        guard count > 0 else { return (next, nil) }
        return (next, ((next.cursor % count) + count) % count)
    }

    enum Source: Equatable { case dynamic(DayPhase), pinned, rotation(Int) }

    struct Choice: Equatable {
        let id: String
        let source: Source
    }

    /// 優先序：日夜模式 → 釘選 → 輪換（可只限收藏；沒有收藏時用全部）。
    /// 只有真的走到輪換時才更新游標狀態。
    /// - Parameter dynamicPhaseIDs: 日夜模式啟用時，四時段各自的檔案 id；nil＝未啟用。
    static func choose(at date: Date,
                       dynamicPhaseIDs: [DayPhase: String]?,
                       pinnedID: String?,
                       available: [String],
                       favorites: Set<String>,
                       favoritesOnly: Bool,
                       state: RotationState,
                       force: Bool = false,
                       delta: Int = 1,
                       frequency: RotationFrequency = .hourly,
                       calendar: Calendar = .current) -> (choice: Choice?, state: RotationState) {
        if let ids = dynamicPhaseIDs {
            let phase = DayPhase.current(at: date, calendar: calendar)
            if let id = ids[phase] { return (Choice(id: id, source: .dynamic(phase)), state) }
        }
        if let pinnedID, available.contains(pinnedID) { return (Choice(id: pinnedID, source: .pinned), state) }
        var pool = available
        if favoritesOnly {
            let favs = available.filter { favorites.contains($0) }
            if !favs.isEmpty { pool = favs }
        }
        // everyRun：每次呼叫都前進（第一次也前進，用游標當格號）。
        let slotValue = slot(at: date, frequency: frequency, calendar: calendar)
        let result = slotValue.map { step(state, slot: $0, count: pool.count, force: force, delta: delta) }
            ?? step(state, slot: state.cursor, count: pool.count, force: true, delta: force ? delta : 1)
        guard let index = result.index else { return (nil, state) }
        return (Choice(id: pool[index], source: .rotation(index)), result.state)
    }
}
