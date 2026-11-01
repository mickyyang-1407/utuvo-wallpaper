import Foundation

/// 日夜四時段，切換點與 Mac `DynamicPhase.current` 相同。
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
    var time: String {
        switch self {
        case .dawn: return "06:00"
        case .day: return "09:00"
        case .dusk: return "18:00"
        case .night: return "21:00"
        }
    }
    var symbol: String {
        switch self {
        case .dawn: return "sunrise"
        case .day: return "sun.max"
        case .dusk: return "sunset"
        case .night: return "moon.stars"
        }
    }

    /// 純函式：06–09 清晨、09–18 白天、18–21 黃昏，其餘夜晚。
    static func current(hour: Int) -> Self {
        switch hour {
        case 6..<9: return .dawn
        case 9..<18: return .day
        case 18..<21: return .dusk
        default: return .night
        }
    }

    static func current(at date: Date, calendar: Calendar = .current) -> Self {
        current(hour: calendar.component(.hour, from: date))
    }

    /// 白天直接用生成的底圖，其餘三個時段用 edits 換光線。
    var relightPrompt: String {
        let lighting: String
        switch self {
        case .day: lighting = "clear daytime"
        case .dawn: lighting = "early dawn, pale pink horizon, low golden light, cool mist"
        case .dusk: lighting = "sunset twilight, warm amber horizon and cool violet shadows"
        case .night: lighting = "deep night, dark blue sky with stars, subtle moonlight and warm cabin window lights"
        }
        return """
        Relight this exact reference photograph to \(lighting).
        Preserve the identical camera, framing, perspective, horizon, terrain, buildings,
        trees, shoreline and all object positions. Change only illumination, exposure,
        sky color and physically appropriate reflections. No new objects, text or watermark.
        Output the same vertical 9:16 scene, fully aligned to the reference.
        """
    }

    static func basePrompt(scene: String) -> String {
        """
        Create one calm photographic phone landscape: \(scene).
        Clear daytime lighting, fixed tripod, vertical 9:16 iPhone wallpaper composition, no text or watermark.
        Strong stable silhouettes and detailed natural materials. Keep the main subject in the middle and lower \
        two thirds so the clock area at the top stays calm. This is the exact reference for a day/night set.
        """
    }
}
