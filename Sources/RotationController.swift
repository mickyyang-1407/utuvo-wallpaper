import Foundation

/// 輪換控制器。預設關閉，只有使用者按下啟動才會開始。
@MainActor
final class RotationController {
    enum Mode: String, CaseIterable, Identifiable {
        case off
        case hourly
        case fiveMinutes
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return L("關閉（不輪換）")
            case .hourly: return L("每小時")
            case .fiveMinutes: return L("每 5 分鐘")
            case .manual: return L("手動（按上一張／下一張時套用）")
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .off, .manual: return nil
            case .hourly: return 3600
            case .fiveMinutes: return 300
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
