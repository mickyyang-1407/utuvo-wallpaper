import Foundation

/// 共用的 `DynamicSchedule`（../Sources）用 Mac 的型別名稱。
typealias DynamicPhase = DayPhase

/// 日夜四時段；切換時間由共用的 `DynamicSchedule` 決定（固定 06／09／18／21 或依日出日落）。
enum DayPhase: String, CaseIterable, Identifiable, Codable, Sendable {
    case dawn, day, dusk, night
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dawn: return L("清晨")
        case .day: return L("白天")
        case .dusk: return L("黃昏")
        case .night: return L("夜晚")
        }
    }
    /// 依目前的切換方式顯示今天的開始時間。
    var time: String { DynamicSchedule.load().startTime(of: self) }
    var symbol: String {
        switch self {
        case .dawn: return "sunrise"
        case .day: return "sun.max"
        case .dusk: return "sunset"
        case .night: return "moon.stars"
        }
    }

    /// 固定時間的純函式：06–09 清晨、09–18 白天、18–21 黃昏，其餘夜晚。
    static func current(hour: Int) -> Self {
        switch hour {
        case 6..<9: return .dawn
        case 9..<18: return .day
        case 18..<21: return .dusk
        default: return .night
        }
    }

    static func current(at date: Date, calendar: Calendar = .current, defaults: UserDefaults = .standard) -> Self {
        DynamicSchedule.load(defaults).phase(at: date, isDark: false, calendar: calendar)
    }

    /// 白天直接用生成的底圖，其餘三個時段用 edits 換光線（提示詞與 Mac 共用 ScenePrompt）。
    var relightPrompt: String { ScenePrompt.relight(rawValue, canvas: .phone) }

    static func basePrompt(scene: String) -> String { ScenePrompt.base(scene, canvas: .phone) }
}
