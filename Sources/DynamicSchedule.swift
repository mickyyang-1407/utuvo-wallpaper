import Foundation

/// 日夜場景什麼時候換時段。
/// - fixed：固定 06／09／18／21（舊行為）。
/// - solar：依所在地當天日出日落（清晨＝日出前 30 分起，白天＝日出後 90 分起，黃昏＝日落前 90 分起，夜晚＝日落後 30 分起）。
/// - appearance：跟系統外觀，淺色＝白天、深色＝夜晚。
enum DynamicTiming: String, CaseIterable, Identifiable, Sendable {
    case fixed, solar, appearance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixed: return L("固定時間（06／09／18／21）")
        case .solar: return L("依日出日落")
        case .appearance: return L("跟著系統淺色／深色")
        }
    }

    static let defaultsKey = "dynamic.timing"
    static func load(_ defaults: UserDefaults = .standard) -> DynamicTiming {
        defaults.string(forKey: defaultsKey).flatMap(DynamicTiming.init(rawValue:)) ?? .fixed
    }
}

struct Coordinate: Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    static let latitudeKey = "dynamic.latitude"
    static let longitudeKey = "dynamic.longitude"

    /// 使用者存過的位置；沒有就用時區推估。
    static func load(_ defaults: UserDefaults = .standard, timeZone: TimeZone = .current) -> (Coordinate, fromTimeZone: Bool) {
        if let lat = defaults.object(forKey: latitudeKey) as? Double,
           let lon = defaults.object(forKey: longitudeKey) as? Double,
           (-90...90).contains(lat), (-180...180).contains(lon) {
            return (Coordinate(latitude: lat, longitude: lon), false)
        }
        return (estimate(for: timeZone), true)
    }

    static func save(_ coordinate: Coordinate?, to defaults: UserDefaults = .standard) {
        if let coordinate {
            defaults.set(coordinate.latitude, forKey: latitudeKey)
            defaults.set(coordinate.longitude, forKey: longitudeKey)
        } else {
            defaults.removeObject(forKey: latitudeKey)
            defaults.removeObject(forKey: longitudeKey)
        }
        defaults.synchronize()
    }

    /// 常見時區的代表城市；不在表內就用 UTC 偏移推經度、緯度取 30°（只影響日出日落幾分鐘）。
    static func estimate(for timeZone: TimeZone) -> Coordinate {
        if let known = timeZoneCities[timeZone.identifier] { return Coordinate(latitude: known.0, longitude: known.1) }
        let hours = Double(timeZone.secondsFromGMT()) / 3600
        return Coordinate(latitude: 30, longitude: max(-180, min(180, hours * 15)))
    }

    private static let timeZoneCities: [String: (Double, Double)] = [
        "Asia/Taipei": (25.03, 121.56), "Asia/Tokyo": (35.68, 139.69), "Asia/Seoul": (37.57, 126.98),
        "Asia/Shanghai": (31.23, 121.47), "Asia/Hong_Kong": (22.32, 114.17), "Asia/Macau": (22.20, 113.54),
        "Asia/Singapore": (1.35, 103.82), "Asia/Kuala_Lumpur": (3.14, 101.69), "Asia/Bangkok": (13.76, 100.50),
        "Asia/Ho_Chi_Minh": (10.82, 106.63), "Asia/Manila": (14.60, 120.98), "Asia/Jakarta": (-6.21, 106.85),
        "Asia/Kolkata": (19.08, 72.88), "Asia/Dubai": (25.20, 55.27), "Asia/Jerusalem": (31.77, 35.21),
        "Europe/London": (51.51, -0.13), "Europe/Dublin": (53.35, -6.26), "Europe/Paris": (48.86, 2.35),
        "Europe/Berlin": (52.52, 13.40), "Europe/Amsterdam": (52.37, 4.90), "Europe/Brussels": (50.85, 4.35),
        "Europe/Madrid": (40.42, -3.70), "Europe/Lisbon": (38.72, -9.14), "Europe/Rome": (41.90, 12.50),
        "Europe/Zurich": (47.38, 8.54), "Europe/Vienna": (48.21, 16.37), "Europe/Stockholm": (59.33, 18.07),
        "Europe/Oslo": (59.91, 10.75), "Europe/Copenhagen": (55.68, 12.57), "Europe/Helsinki": (60.17, 24.94),
        "Europe/Warsaw": (52.23, 21.01), "Europe/Prague": (50.08, 14.44), "Europe/Athens": (37.98, 23.73),
        "Europe/Istanbul": (41.01, 28.98), "Europe/Moscow": (55.76, 37.62),
        "America/New_York": (40.71, -74.01), "America/Toronto": (43.65, -79.38), "America/Chicago": (41.88, -87.63),
        "America/Denver": (39.74, -104.99), "America/Phoenix": (33.45, -112.07), "America/Los_Angeles": (34.05, -118.24),
        "America/Vancouver": (49.28, -123.12), "America/Anchorage": (61.22, -149.90), "Pacific/Honolulu": (21.31, -157.86),
        "America/Mexico_City": (19.43, -99.13), "America/Sao_Paulo": (-23.55, -46.63), "America/Argentina/Buenos_Aires": (-34.60, -58.38),
        "America/Bogota": (4.71, -74.07), "America/Lima": (-12.05, -77.04), "America/Santiago": (-33.45, -70.67),
        "Australia/Sydney": (-33.87, 151.21), "Australia/Melbourne": (-37.81, 144.96), "Australia/Brisbane": (-27.47, 153.03),
        "Australia/Perth": (-31.95, 115.86), "Pacific/Auckland": (-36.85, 174.76), "Africa/Johannesburg": (-26.20, 28.05),
        "Africa/Cairo": (30.04, 31.24), "Africa/Lagos": (6.52, 3.38), "Africa/Nairobi": (-1.29, 36.82),
    ]
}

/// 日出日落（NOAA 簡化公式，誤差約 1–2 分鐘）。回傳當地「從午夜起的分鐘數」；極晝極夜回 nil。
enum SolarCalculator {
    static func sunriseSunset(on date: Date, at coordinate: Coordinate, calendar: Calendar = .current) -> (sunrise: Int, sunset: Int)? {
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        // 用當天中午的時差：日光節約通常在凌晨切換，午夜的時差會是切換前的。
        let localNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let offsetMinutes = Double(calendar.timeZone.secondsFromGMT(for: localNoon)) / 60
        let gamma = 2 * Double.pi / 365 * Double(dayOfYear - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                               - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma) - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma) - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let lat = coordinate.latitude * .pi / 180
        let zenith = 90.833 * Double.pi / 180
        let cosHA = cos(zenith) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
        guard (-1...1).contains(cosHA) else { return nil }
        let ha = acos(cosHA) * 180 / .pi
        let noon = 720 - 4 * coordinate.longitude - eqTime + offsetMinutes
        let sunrise = Int((noon - 4 * ha).rounded())
        let sunset = Int((noon + 4 * ha).rounded())
        return (sunrise, sunset)
    }
}

/// 一天裡四個時段的起點（分鐘）。所有畫面與背景排程都從這裡取，避免各算各的。
struct DynamicSchedule: Sendable {
    var timing: DynamicTiming
    var coordinate: Coordinate

    static func load(_ defaults: UserDefaults = .standard) -> DynamicSchedule {
        DynamicSchedule(timing: DynamicTiming.load(defaults), coordinate: Coordinate.load(defaults).0)
    }

    static let fixedStarts: [DynamicPhase: Int] = [.dawn: 6 * 60, .day: 9 * 60, .dusk: 18 * 60, .night: 21 * 60]

    /// 當天四個起點；solar 算不出來（極晝極夜）或時段擠在一起時退回固定時間。
    func starts(on date: Date, calendar: Calendar = .current) -> [DynamicPhase: Int] {
        guard timing == .solar,
              let sun = SolarCalculator.sunriseSunset(on: date, at: coordinate, calendar: calendar) else { return Self.fixedStarts }
        let starts: [DynamicPhase: Int] = [.dawn: sun.sunrise - 30, .day: sun.sunrise + 90,
                                           .dusk: sun.sunset - 90, .night: sun.sunset + 30]
        let ordered = [starts[.dawn]!, starts[.day]!, starts[.dusk]!, starts[.night]!]
        guard ordered.first! >= 0, ordered.last! < 1440, zip(ordered, ordered.dropFirst()).allSatisfy({ $0 < $1 }) else {
            return Self.fixedStarts
        }
        return starts
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// `isDark` 只有 appearance 模式會用。
    func phase(at date: Date, isDark: Bool = SystemAppearance.isDark(), calendar: Calendar = .current) -> DynamicPhase {
        if timing == .appearance { return isDark ? .night : .day }
        let starts = starts(on: date, calendar: calendar)
        let minute = Self.minuteOfDay(date, calendar: calendar)
        if minute >= starts[.night]! || minute < starts[.dawn]! { return .night }
        if minute >= starts[.dusk]! { return .dusk }
        if minute >= starts[.day]! { return .day }
        return .dawn
    }

    /// 24 小時時間軸色段（分鐘），夜晚跨午夜拆成頭尾兩段。appearance 模式沒有時間軸，回空。
    func segments(on date: Date, calendar: Calendar = .current) -> [(phase: DynamicPhase, start: Int, end: Int)] {
        guard timing != .appearance else { return [] }
        let s = starts(on: date, calendar: calendar)
        return [(.night, 0, s[.dawn]!), (.dawn, s[.dawn]!, s[.day]!), (.day, s[.day]!, s[.dusk]!),
                (.dusk, s[.dusk]!, s[.night]!), (.night, s[.night]!, 1440)]
    }

    /// 下一個時段與它開始的時刻（今天或明天）。appearance 模式回 nil。
    func next(after date: Date, calendar: Calendar = .current) -> (phase: DynamicPhase, at: Date)? {
        guard timing != .appearance else { return nil }
        let minute = Self.minuteOfDay(date, calendar: calendar)
        let today = starts(on: date, calendar: calendar).sorted { $0.value < $1.value }
        let dayStart = calendar.startOfDay(for: date)
        // 用「幾點幾分」組日期，日光節約那天也不會差一小時。
        func at(_ minutes: Int, on day: Date) -> Date? {
            calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
        }
        if let upcoming = today.first(where: { $0.value > minute }), let date = at(upcoming.value, on: dayStart) {
            return (upcoming.key, date)
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let first = starts(on: tomorrow, calendar: calendar).min(by: { $0.value < $1.value }),
              let date = at(first.value, on: tomorrow) else { return nil }
        return (first.key, date)
    }

    static func clock(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    func startTime(of phase: DynamicPhase, on date: Date = Date()) -> String {
        timing == .appearance ? (phase == .night ? L("深色") : L("淺色")) : Self.clock(starts(on: date)[phase]!)
    }

    func range(of phase: DynamicPhase, on date: Date = Date()) -> String {
        if timing == .appearance { return startTime(of: phase, on: date) }
        let s = starts(on: date)
        let end: Int
        switch phase {
        case .dawn: end = s[.day]!
        case .day: end = s[.dusk]!
        case .dusk: end = s[.night]!
        case .night: end = s[.dawn]!
        }
        return Self.clock(s[phase]!) + "–" + Self.clock(end)
    }
}

enum SystemAppearance {
    /// 背景程序沒有視窗，直接讀全域偏好；GUI 與背景結果一致。
    static func isDark() -> Bool {
        UserDefaults(suiteName: UserDefaults.globalDomain)?.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}
