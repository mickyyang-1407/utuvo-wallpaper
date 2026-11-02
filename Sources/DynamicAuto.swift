import Foundation

/// 日夜「AI 自動」：每天或每週自動挑一個新場景，生成四時段。Mac 與 iPhone 共用。
enum DynamicAutoFrequency: String, CaseIterable, Identifiable, Sendable {
    case off, daily, weekly
    var id: String { rawValue }
    static let key = "dynamic.auto.frequency"

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .off
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.key) }

    var title: String {
        switch self {
        case .off: return L("自己描述")
        case .daily: return L("AI 自動・每天")
        case .weekly: return L("AI 自動・每週")
        }
    }
}

/// 自動場景的進度。付費請求送出前先記 attempts，當機也不會重置重試次數。
struct DynamicAutoState: Codable, Equatable, Sendable {
    var period: String
    var subject: String
    var prompt: String
    var sceneID: String
    var attempts = 0
    var retryAfter: Date?
    var completed = false
    /// 最近用過的主題 id，挑新主題時避開。
    var recentSubjects: [String] = []

    static let maxAttempts = 3
    static let retryDelay: TimeInterval = 30 * 60

    static func load(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// 生成失敗：可重試的錯誤 30 分鐘後再試，其他錯誤這一期不再自動試。
    mutating func recordFailure(retryable: Bool, now: Date) {
        if retryable, attempts < Self.maxAttempts { retryAfter = now.addingTimeInterval(Self.retryDelay) }
        else { attempts = Self.maxAttempts }
    }

    mutating func recordSuccess() {
        completed = true
        retryAfter = nil
        recentSubjects = Array((recentSubjects + [subject]).suffix(DynamicAutoPlanner.recentLimit))
    }
}

enum DynamicAutoPlanner {
    static let recentLimit = 6

    struct Subject: Sendable {
        let id: String
        let zh: String
        let en: String
        var winterOnly = false
    }

    /// 構圖固定、輪廓清楚的場景，換光線時才對得齊。
    static let subjects: [Subject] = [
        Subject(id: "lake-cabin", zh: "山間湖畔的木屋與松林", en: "a wooden cabin beside a still mountain lake with pine forest"),
        Subject(id: "lighthouse", zh: "海岬岩岸上的白色燈塔", en: "a white lighthouse on a rocky headland above the sea"),
        Subject(id: "tea-terrace", zh: "山坡梯田茶園與一間農舍", en: "terraced mountain tea fields with a small farmhouse"),
        Subject(id: "stone-bridge", zh: "老村落裡跨過小河的石橋", en: "an old stone bridge over a slow river in a quiet village"),
        Subject(id: "desert-road", zh: "沙漠台地與一條筆直公路", en: "desert mesas with a single straight road"),
        Subject(id: "cliff-town", zh: "海崖上的白色小鎮", en: "a small white town on sea cliffs"),
        Subject(id: "greenhouse", zh: "植物園裡的玻璃溫室", en: "a glass greenhouse in a botanical garden"),
        Subject(id: "boathouse", zh: "湖邊船屋與木棧橋", en: "a lakeside boathouse with a wooden pier"),
        Subject(id: "bamboo-shrine", zh: "竹林小徑盡頭的小神社", en: "a bamboo forest path leading to a small shrine"),
        Subject(id: "observatory", zh: "高山稜線上的天文台", en: "an observatory dome on a high mountain ridge"),
        Subject(id: "red-barn", zh: "麥田丘陵間的紅色穀倉", en: "a red barn among rolling wheat fields"),
        Subject(id: "harbor", zh: "停滿漁船的小漁港", en: "a small fishing harbor with moored boats"),
        Subject(id: "hill-house", zh: "森林山坡上的清水模住宅", en: "a modern concrete house on a forested hillside"),
        Subject(id: "windmill", zh: "運河旁平原上的風車", en: "a windmill on a flat plain beside canals"),
        Subject(id: "viaduct", zh: "橫跨山谷的鐵道高架橋", en: "a mountain railway viaduct across a valley"),
        Subject(id: "island-tree", zh: "平靜海灣中的小島與一棵樹", en: "a small island with a single tree in a calm bay"),
        Subject(id: "canyon", zh: "砂岩峽谷中的河灣", en: "a river bend between sandstone canyon walls"),
        Subject(id: "fjord", zh: "峽灣邊的紅色小屋", en: "a red cabin on the shore of a fjord"),
        Subject(id: "skyline", zh: "隔著港灣的城市天際線", en: "a city skyline across a calm harbor"),
        Subject(id: "orchard", zh: "果園裡的石砌小屋", en: "a small stone cottage in an orchard"),
        Subject(id: "tidal-walk", zh: "潮間帶上的木棧道", en: "a wooden boardwalk across tidal flats"),
        Subject(id: "alpine-hut", zh: "鋸齒雪峰下的高山小屋", en: "an alpine hut below jagged snowy peaks", winterOnly: true),
        Subject(id: "onsen-inn", zh: "雪谷裡的溫泉旅館", en: "a hot-spring inn in a snowy valley", winterOnly: true),
    ]

    static let weathers: [(zh: String, en: String)] = [
        ("空氣清澈", "clear air"), ("薄霧", "light haze"), ("雨後", "after a gentle rain"),
    ]

    /// 這一期的代號：每天＝日期，每週＝ISO 週。關閉時回 nil。
    static func period(for date: Date, frequency: DynamicAutoFrequency, calendar: Calendar = .current) -> String? {
        switch frequency {
        case .off: return nil
        case .daily:
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        case .weekly:
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        }
    }

    enum Season { case spring, summer, autumn, winter }

    static func season(for date: Date, calendar: Calendar = .current, southern: Bool = false) -> Season {
        var month = calendar.component(.month, from: date)
        if southern { month = (month + 5) % 12 + 1 }
        switch month {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .autumn
        default: return .winter
        }
    }

    /// 字串雜湊（FNV-1a）；Swift 內建 hashValue 每次執行不同，不能用。
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    /// 挑主題：同一期結果固定；避開最近用過的、冬季限定只在冬天出現。
    static func pick(period: String, salt: Int = 0, season: Season, recent: [String], chinese: Bool) -> (subject: String, prompt: String) {
        let seasonal = subjects.filter { !$0.winterOnly || season == .winter }
        let fresh = seasonal.filter { !recent.contains($0.id) }
        let pool = fresh.isEmpty ? seasonal : fresh
        let hash = stableHash("\(period)#\(salt)")
        let subject = pool[Int(hash % UInt64(pool.count))]
        let weather = weathers[Int((hash >> 20) % UInt64(weathers.count))]
        let seasonText: (zh: String, en: String)
        switch season {
        case .spring: seasonText = ("春天", "spring")
        case .summer: seasonText = ("夏天", "summer")
        case .autumn: seasonText = ("秋天", "autumn")
        case .winter: seasonText = ("冬天", "winter")
        }
        let prompt = chinese ? "\(subject.zh)，\(seasonText.zh)，\(weather.zh)"
                             : "\(subject.en), \(seasonText.en), \(weather.en)"
        return (subject.id, prompt)
    }

    /// 排程：到期就回傳要做的狀態（新的一期或續作），否則 nil。
    static func due(state: DynamicAutoState?, now: Date, frequency: DynamicAutoFrequency,
                    calendar: Calendar = .current, southern: Bool = false, chinese: Bool) -> DynamicAutoState? {
        guard let period = period(for: now, frequency: frequency, calendar: calendar) else { return nil }
        if let state, state.period == period {
            guard !state.completed, state.attempts < DynamicAutoState.maxAttempts else { return nil }
            if let retryAfter = state.retryAfter, retryAfter > now { return nil }
            return state
        }
        return fresh(period: period, salt: 0, previous: state, now: now, calendar: calendar, southern: southern, chinese: chinese)
    }

    /// 手動「現在生成一組」：沒做完就續作；這期已完成就換一個主題重來。
    static func manual(state: DynamicAutoState?, now: Date, frequency: DynamicAutoFrequency,
                       calendar: Calendar = .current, southern: Bool = false, chinese: Bool) -> DynamicAutoState {
        let period = period(for: now, frequency: frequency == .off ? .daily : frequency, calendar: calendar) ?? "manual"
        if let state, state.period == period, !state.completed {
            var resumed = state
            resumed.attempts = min(resumed.attempts, DynamicAutoState.maxAttempts - 1)
            resumed.retryAfter = nil
            return resumed
        }
        let salt = (state?.period == period) ? Int(now.timeIntervalSince1970) : 0
        return fresh(period: period, salt: salt, previous: state, now: now, calendar: calendar, southern: southern, chinese: chinese)
    }

    private static func fresh(period: String, salt: Int, previous: DynamicAutoState?, now: Date,
                              calendar: Calendar, southern: Bool, chinese: Bool) -> DynamicAutoState {
        var recent = previous?.recentSubjects ?? []
        // 上一期沒做完的主題也算用過，避免連續兩期同一個。
        if let previous, !previous.completed { recent = Array((recent + [previous.subject]).suffix(recentLimit)) }
        let choice = pick(period: period, salt: salt, season: season(for: now, calendar: calendar, southern: southern),
                          recent: recent, chinese: chinese)
        let id = "ai-\(period)-\(String(stableHash("\(period)#\(salt)#\(choice.subject)") % 1_000_000))"
        return DynamicAutoState(period: period, subject: choice.subject, prompt: choice.prompt, sceneID: id,
                                recentSubjects: recent)
    }
}
