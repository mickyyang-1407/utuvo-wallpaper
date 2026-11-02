import SwiftUI
import AppKit

/// STYLE.md（2026-11-01）配色與共用外觀元件。只管外觀，不碰資料。
enum WallpaperPalette {
    /// 主要動作藍（按鈕、選取外框、tint）。
    static let accent = hex(0x3B82F6)
    static let accentDeep = hex(0x2563EB)
    static let sidebarSelection = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.80, alpha: 1)
    })
    static let canvas = surface(light: 0xF4F5F7, dark: 0x14171D)
    static let panel = surface(light: 0xECEEF2, dark: 0x1A1E25)
    static let glow = surface(light: 0x2A3B5C, dark: 0x2A3B5C)
    /// 次要文字：淺色模式比系統 .secondary 深，避免偏淡。
    static let secondaryText = surface(light: 0x50555D, dark: 0x9EA3AB)
    /// 淺色浮動操作列用中性白，不透出底圖顏色。
    static let floatingBarLight = hex(0xFBFBFC)

    static let green = hex(0x30D158)
    static let orange = hex(0xFF9F0A)
    static let blue = hex(0x0A84FF)
    static let red = hex(0xFF453A)
    /// 破壞性按鈕底色（白字對比 ≥ 4.5:1）。
    static let destructive = hex(0xC42B2B)

    /// 標籤色顯示用：飽和度降約 22%，不搶桌布（存檔的色碼不變）。
    static func muted(_ string: String) -> Color {
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return hex(0x8E8E93) }
        let color = NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return Color(nsColor: NSColor(hue: h, saturation: sat * 0.78, brightness: b * 0.94, alpha: 1))
    }

    /// 解析度級距對應的玻璃方塊（同色）。
    static func resolutionGlass(_ tier: ResolutionTier) -> String {
        switch tier {
        case .sixK: return "all"
        case .fiveK: return "cosmic"
        case .fourK: return "watercolor"
        case .other: return "other"
        }
    }

    /// 解析度級距的圖示色。
    static func resolutionColor(_ tier: ResolutionTier) -> Color {
        switch tier {
        case .sixK: return hex(0x0A84FF)
        case .fiveK: return hex(0x5E5CE6)
        case .fourK: return hex(0x40C8E0)
        case .other: return hex(0x636366)
        }
    }

    static func hex(_ rgb: UInt32) -> Color {
        Color(.sRGB,
              red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255,
              opacity: 1)
    }

    /// "#RRGGBB" → Color；格式不對時退回中性灰。
    static func hex(string: String) -> Color {
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return hex(0x8E8E93) }
        return hex(value)
    }

    static func surface(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb: UInt32 = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            let red = CGFloat((rgb >> 16) & 255) / 255.0
            let green = CGFloat((rgb >> 8) & 255) / 255.0
            let blue = CGFloat(rgb & 255) / 255.0
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        })
    }

    /// 分類固定色（STYLE.md）。
    static func categoryColor(_ name: String) -> Color {
        switch name {
        case "自然": return hex(0x30D158)
        case "極簡": return hex(0x8E8E93)
        case "抽象": return hex(0x7D5CFF)
        case "插畫": return hex(0xFF9F0A)
        case "宇宙": return hex(0x5E5CE6)
        case "水彩": return hex(0x40C8E0)
        case "建築": return hex(0xC9A26B)
        case "動畫": return hex(0xFF6482)
        case "純色": return hex(0x64D2FF)
        case "漸層": return hex(0xBF5AF2)
        case "深色": return hex(0x48484A)
        case "幾何": return hex(0x0A84FF)
        case "城市": return hex(0xFF453A)
        case "動物": return hex(0xA2845E)
        case "3D": return hex(0x5AC8FA)
        default: return hex(0x636366)
        }
    }

    static func categorySymbol(_ name: String) -> String {
        switch name {
        case "自然": return "leaf.fill"
        case "極簡": return "square"
        case "抽象": return "scribble.variable"
        case "插畫": return "paintbrush.pointed.fill"
        case "宇宙": return "sparkles"
        case "水彩": return "paintpalette.fill"
        case "建築": return "building.columns.fill"
        case "動畫": return "film.fill"
        case "純色": return "circle.fill"
        case "漸層": return "circle.lefthalf.filled"
        case "深色": return "moon.fill"
        case "幾何": return "hexagon.fill"
        case "城市": return "building.2.fill"
        case "動物": return "pawprint.fill"
        case "3D": return "cube.fill"
        default: return "photo"
        }
    }
}

/// 視窗底色＋頂部中央淡藍光暈。
struct CanvasBackground: View {
    @Environment(\.colorScheme) private var scheme
    /// Liquid Glass 背景：目前選的桌布，大幅模糊後淡淡鋪在底下，玻璃才透得出顏色。
    var backdrop: NSImage? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WallpaperPalette.canvas
                if #available(macOS 26, *), let backdrop {
                    // 鮮明霧面：桌布不淡化、只模糊，顏色飽滿地透進玻璃。
                    Image(nsImage: backdrop)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 36)
                        .saturation(1.35)
                        .clipped()
                        .animation(.easeInOut(duration: 0.4), value: backdrop)
                    // 字要讀得清楚：淺色模式壓一層白、深色模式壓一層黑，讓標題字跟背景拉開對比。
                    (scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.30))
                }
                RadialGradient(
                    colors: [WallpaperPalette.glow.opacity(backdrop == nil ? (scheme == .dark ? 0.55 : 0.12) : 0), .clear],
                    center: UnitPoint(x: 0.5, y: 0),
                    startRadius: 0,
                    endRadius: max(geometry.size.width, 600) * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}

/// 彩色圓角圖示方塊：Blender 玻璃方塊 PNG 當底＋白色 SF Symbol；找不到圖就退回漸層色塊。
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24
    /// 玻璃方塊名稱（Assets/GlassTiles/<名稱>）；nil＝依符號推斷。
    var glass: String? = nil

    /// STYLE.md 的符號 → 方塊顏色名稱。
    static let glassBySymbol: [String: String] = [
        "photo.on.rectangle": "all", "heart.fill": "favorites", "sun.max.fill": "dynamic",
        "leaf.fill": "nature", "square": "minimal", "scribble.variable": "abstract",
        "paintbrush.pointed.fill": "illustration", "sparkles": "cosmic", "paintpalette.fill": "watercolor",
        "building.columns.fill": "architecture", "film.fill": "animation", "photo": "other",
        "gearshape.fill": "settings",
    ]

    var body: some View {
        if let image = GlassTileImages.image(glass ?? Self.glassBySymbol[symbol], points: size) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.22), radius: size * 0.04, y: size * 0.02))
                .accessibilityHidden(true)
        } else {
            gradientTile
        }
    }

    private var gradientTile: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.88), color],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 讀 bundle 裡的玻璃方塊（依顯示大小挑 48／72／96px），讀過就快取。
enum GlassTileImages {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    static func image(_ name: String?, points: CGFloat) -> NSImage? {
        guard let name else { return nil }
        let pixels = points * 2
        let size = [48, 72, 96].first { CGFloat($0) >= pixels } ?? 96
        let key = "\(name)-\(size)"
        if let hit = cache[key] { return hit }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("GlassTiles/\(key).png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image
        return image
    }
}

/// 卡片底：深色白 5%＋白 8% 框；淺色白底＋黑 6% 框。
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 16
    var selected = false

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // Liquid Glass：卡片變玻璃，選取時加品牌藍框。
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(selected ? WallpaperPalette.accent : Color.clear, lineWidth: 2))
        } else {
            solid(content)
        }
    }

    private func solid(_ content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.05) : Color.white))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? WallpaperPalette.accent
                                  : (scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)),
                                  lineWidth: selected ? 2 : 1))
    }
}

extension View {
    func wallpaperCard(radius: CGFloat = 16, selected: Bool = false) -> some View {
        modifier(CardBackground(radius: radius, selected: selected))
    }
}

/// 分類色填色藥丸。
struct Pill: View {
    let text: String
    let color: Color
    var fontSize: CGFloat = 13

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, fontSize * 0.7)
            .padding(.vertical, fontSize * 0.22)
            .background(Capsule().fill(color))
    }
}

/// 藍色主要膠囊按鈕。
struct PrimaryCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .modifier(PrimaryCapsuleBackground())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// 主要按鈕底：macOS 26 是藍色染色的互動玻璃，舊系統是藍色漸層膠囊。
private struct PrimaryCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // 保留品牌藍（STYLE.md），玻璃負責邊緣高光與按壓回饋。
            content
                .background(Capsule().fill(LinearGradient(colors: [WallpaperPalette.accent, WallpaperPalette.accentDeep],
                                                          startPoint: .top, endPoint: .bottom)))
                .glassEffect(.clear.interactive(), in: Capsule())
        } else {
            content.background(
                Capsule().fill(LinearGradient(colors: [WallpaperPalette.accent, WallpaperPalette.accentDeep],
                                              startPoint: .top, endPoint: .bottom)))
        }
    }
}

/// 次要膠囊按鈕（狀態卡的「查看」）。
struct SecondaryCapsuleStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    /// 有色次要按鈕（例：紅色「移到垃圾桶」）：字用該色、底用該色淡底。
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint ?? Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .modifier(SecondaryCapsuleBackground(fill: background(pressed: configuration.isPressed), tint: tint))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }

    private func background(pressed: Bool) -> Color {
        if let tint { return tint.opacity(pressed ? 0.26 : 0.16) }
        return scheme == .dark ? Color.white.opacity(pressed ? 0.16 : 0.1) : Color.black.opacity(pressed ? 0.1 : 0.06)
    }
}

/// 次要按鈕底：macOS 26 是（可染色的）互動玻璃，舊系統是淡色膠囊。
private struct SecondaryCapsuleBackground: ViewModifier {
    var fill: Color
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if let tint {
                // 有色按鈕：先鋪實的淡色底（對比夠），玻璃只給高光與按壓回饋。
                content
                    .background(Capsule().fill(tint.opacity(0.2)))
                    .glassEffect(.clear.interactive(), in: Capsule())
            } else {
                content.glassEffect(.regular.interactive(), in: Capsule())
            }
        } else {
            content.background(Capsule().fill(fill))
        }
    }
}

/// 斜線紋：同色細斜線，用於分布長條「較舊」的部分。
struct StripeFill: View {
    let color: Color
    var spacing: CGFloat = 7
    var lineWidth: CGFloat = 1.6

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.22)))
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(color.opacity(0.75)), lineWidth: lineWidth)
        }
    }
}

/// 玻璃容器（時間軸、分布長條、狀態卡等）。舊系統退回卡片外觀。
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 16
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular,
                                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.wallpaperCard(radius: radius)
        }
    }
}

extension View {
    func glassPanel(radius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(GlassPanel(radius: radius, tint: tint))
    }
}


/// 紅底白字的破壞性膠囊按鈕（不用玻璃，確保對比）。
struct DestructiveCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(WallpaperPalette.destructive.opacity(configuration.isPressed ? 0.85 : 1)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// 不透明中性膠囊按鈕（確認視窗的「取消」）。
struct NeutralSolidCapsuleStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(scheme == .dark ? Color.white.opacity(configuration.isPressed ? 0.2 : 0.14)
                                                         : Color.black.opacity(configuration.isPressed ? 0.12 : 0.07)))
            .contentShape(Capsule())
    }
}

// MARK: - Liquid Glass 共用元件

/// 文字輸入框：macOS 26 是互動玻璃圓角框，舊系統用標準圓角框。
struct GlassField: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .textFieldStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            content.textFieldStyle(.roundedBorder)
        }
    }
}

/// 下拉選單／小按鈕：macOS 26 用原生玻璃按鈕。
struct GlassControl: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content
        }
    }
}

/// 側欄、檢視器：macOS 26 讓系統的 Liquid Glass 透出來，舊系統維持原本底色。
struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
        } else {
            content.background(WallpaperPalette.panel)
        }
    }
}

extension View {
    func glassField() -> some View { modifier(GlassField()) }
    func glassControl() -> some View { modifier(GlassControl()) }
    func panelBackground() -> some View { modifier(PanelBackground()) }
}

/// 「AI 靈感」按鈕：點一下把主題點子填進旁邊的 Prompt 欄。
struct InspirationButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label("AI 靈感", systemImage: "sparkles").labelStyle(.titleAndIcon) }
            .help("幫你想一個主題，填進 Prompt 欄")
            .glassControl()
            .fixedSize(horizontal: true, vertical: true)
    }
}
