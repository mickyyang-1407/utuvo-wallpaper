import Foundation

/// 輪換控制器。預設關閉，只有使用者按下啟動才會開始。
@MainActor
final class RotationController {
    enum Mode: String, CaseIterable, Identifiable {
        case off
        case fiveMinutes
        case fifteenMinutes
        case thirtyMinutes
        case hourly
        case daily
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return L("關閉（不輪換）")
            case .fiveMinutes: return L("每 5 分鐘")
            case .fifteenMinutes: return L("每 15 分鐘")
            case .thirtyMinutes: return L("每 30 分鐘")
            case .hourly: return L("每小時")
            case .daily: return L("每天")
            case .manual: return L("手動（按上一張／下一張時套用）")
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .off, .manual: return nil
            case .fiveMinutes: return 300
            case .fifteenMinutes: return 900
            case .thirtyMinutes: return 1800
            case .hourly: return 3600
            case .daily: return 86_400
            }
        }
    }

    private var timer: Timer?
    /// 觸發一次輪換時呼叫（由 AppModel 決定要換到哪一張並設為桌面）。
    var onTick: (() -> Void)?

    var mode: Mode = .off {
        didSet { restart() }
    }

    /// 計時器是否正在跑（`off` 與 `manual` 不需要計時器）。
    var isRunning: Bool { timer != nil }

    /// 一次輪換跳動。計時器到期時呼叫它；測試也直接呼叫同一個入口來驗證接線，
    /// 不必真的等 5 分鐘或 1 小時。
    func tick() {
        onTick?()
    }

    private func restart() {
        timer?.invalidate()
        timer = nil
        guard let interval = mode.interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// 每日自動產生設定。
///
/// - 第一次預設關閉，之後保留使用者的每日生成選擇。
/// - 每天最多一批；當天已經嘗試過就不再嘗試（避免失敗時無限重試、避免重複計費）。
/// - 由 App 或登入後的背景程序檢查；兩者共用一次／日與工作鎖。
@MainActor
final class DailyScheduler {
    enum Mode: Int, CaseIterable, Identifiable {
        case off = 0
        case five = 5
        case ten = 10

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .off: return L("關閉")
            case .five: return L("每日 5 張")
            case .ten: return L("每日 10 張")
            }
        }

        var count: Int { rawValue }
    }

    private let defaults: UserDefaults
    private let attemptKey = "daily.lastAttemptDate"
    private static let modeKey = "daily.mode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mode = Mode(rawValue: defaults.integer(forKey: Self.modeKey)) ?? .off
    }

    var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// 今天是否已經嘗試過產生。
    func alreadyAttempted(on date: Date = Date()) -> Bool {
        defaults.string(forKey: attemptKey) == Self.dayKey(date)
    }

    /// 記錄「今天已經嘗試過」——成功或失敗都記，避免失敗時無限重試。
    func markAttempt(on date: Date = Date()) {
        defaults.set(Self.dayKey(date), forKey: attemptKey)
        defaults.synchronize()
    }

    static func dayKey(_ date: Date) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// 輪換挑圖與「上一張」的純函式，方便自我測試。
enum RotationPlan {
    static let historyLimit = 30
    private static let perDisplayMark = "\u{1D}"

    /// 從游標的下一張開始挑 `count` 張；圖池比螢幕少時會重複。游標不在圖池裡就從頭。
    static func next(pool: [String], after cursor: String?, count: Int) -> [String] {
        guard !pool.isEmpty, count > 0 else { return [] }
        let start = cursor.flatMap { pool.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        return (0..<count).map { pool[(start + $0) % pool.count] }
    }

    /// 一筆歷史：一張（所有螢幕／指定螢幕同一張）或「每顆螢幕各一張」。
    /// 每螢幕紀錄以控制字元 U+001D 開頭，螢幕與圖片也用控制字元分隔；檔名不會用到這些字元。
    static func entry(_ id: String) -> String { id }
    static func entry(perDisplay pairs: [(UInt32, String)]) -> String {
        perDisplayMark + pairs.map { "\($0.0)\u{1F}\($0.1)" }.joined(separator: "\u{1E}")
    }
    /// 解回 (螢幕, 圖片)；螢幕 nil＝套用到目前選的螢幕。
    static func decode(_ entry: String) -> [(UInt32?, String)] {
        guard entry.hasPrefix(perDisplayMark) else { return [(nil, entry)] }
        return entry.dropFirst().split(separator: "\u{1E}").compactMap { pair in
            let parts = pair.split(separator: "\u{1F}", maxSplits: 1)
            guard parts.count == 2, let display = UInt32(parts[0]) else { return nil }
            return (display, String(parts[1]))
        }
    }

    /// 歷史最後一筆是目前這張；往前找第一筆跟目前不同、而且圖都還在的。
    /// `remaining` 是回去之後的新歷史（最後一筆就是回去的那筆）；呼叫端要等套用成功才寫回。
    static func previous(in history: [String], existing: Set<String>) -> (entry: String, remaining: [String])? {
        guard let current = history.last else { return nil }
        var rest = Array(history.dropLast())
        while let candidate = rest.last {
            let ids = decode(candidate).map(\.1)
            if candidate != current && !ids.isEmpty && ids.allSatisfy(existing.contains) { return (candidate, rest) }
            rest.removeLast()
        }
        return nil
    }
}
