import Foundation

/// 日夜場景的提示詞（Mac 與 iPhone 共用）。
/// 照使用者寫的畫風與題材畫，不限風景、不限寫實；換時段只改光線，畫風原封不動。
enum ScenePrompt {
    enum Canvas: Sendable { case desktop, phone }

    static let phases = ["dawn", "day", "dusk", "night"]

    /// 第一張（白天）：之後三個時段都從這張改光線。
    static func base(_ scene: String, canvas: Canvas) -> String {
        let frame: String
        switch canvas {
        case .desktop: frame = "wide 16:9 desktop wallpaper"
        case .phone: frame = "vertical 9:16 iPhone wallpaper"
        }
        let phoneNote = canvas == .phone
            ? "\nLeave the top fifth of the frame uncluttered for the lock-screen clock." : ""
        return """
        Create one \(frame) image of: \(scene).
        Follow the art style, medium and subject in that description exactly. It can be anything: \
        hand-painted animation background art, anime, illustration, watercolor, painting, pixel art, 3D render or photography; \
        an interior, a street, a café, a still life, an animal, a character, a city or a landscape. \
        If no style is given, choose one that suits the subject.
        Show it in clear daytime light from one fixed viewpoint with clear, stable shapes, because the same picture \
        will be relit for dawn, dusk and night. Where it fits, include something that shows the time of day, \
        such as sky, a window, lamps or shadows. No text, logos or watermark.\(phoneNote)
        """
    }

    /// 其他時段：同一張圖只換光線。`phase` 是 dawn／day／dusk／night。
    static func relight(_ phase: String, canvas: Canvas) -> String {
        let lighting: String
        switch phase {
        case "dawn": lighting = "early dawn: pale pink and gold light, long soft shadows and a little mist"
        case "dusk": lighting = "sunset: warm amber light, a glowing horizon where there is sky, and cool violet shadows"
        case "night": lighting = "night: a dark blue sky with moonlight or stars where there is sky, darker surroundings, " +
            "and lamps, windows, screens or signs glowing warmly where they exist"
        default: lighting = "clear daytime"
        }
        let frame = canvas == .desktop ? "wide 16:9" : "vertical 9:16"
        return """
        Change the time of day in this exact reference image to \(lighting).
        Keep its art style, medium, line work, brushwork and rendering exactly as they are. Keep the identical framing, \
        viewpoint and every object, character and building in the same place. Change only the light: sky, sun or moon, \
        shadows, color temperature, and lights that would naturally be on or off. Add nothing new, no text or watermark.
        Output the same \(frame) image, fully aligned to the reference.
        """
    }
}
