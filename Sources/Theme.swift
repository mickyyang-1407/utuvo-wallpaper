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

    static func hex(_ rgb: UInt32) -> Color {
        Color(.sRGB,
              red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255,
              opacity: 1)
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
        default: return "photo"
        }
    }
}

/// 視窗底色＋頂部中央淡藍光暈。
struct CanvasBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WallpaperPalette.canvas
                RadialGradient(
                    colors: [WallpaperPalette.glow.opacity(scheme == .dark ? 0.55 : 0.12), .clear],
                    center: UnitPoint(x: 0.5, y: 0),
                    startRadius: 0,
                    endRadius: max(geometry.size.width, 600) * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}

/// 彩色圓角圖示方塊：漸層填色＋白色 SF Symbol。
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
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

/// 卡片底：深色白 5%＋白 8% 框；淺色白底＋黑 6% 框。
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 16
    var selected = false

    func body(content: Content) -> some View {
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
            .background(
                Capsule().fill(LinearGradient(colors: [WallpaperPalette.accent, WallpaperPalette.accentDeep],
                                              startPoint: .top, endPoint: .bottom)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// 次要膠囊按鈕（狀態卡的「查看」）。
struct SecondaryCapsuleStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(scheme == .dark ? Color.white.opacity(configuration.isPressed ? 0.16 : 0.1)
                                       : Color.black.opacity(configuration.isPressed ? 0.1 : 0.06)))
            .contentShape(Capsule())
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
