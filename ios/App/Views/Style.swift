import SwiftUI
import UIKit

/// 介面風格（design/STYLE.md，與 macOS 同家族）：深色為主、頂部淡藍光暈、彩色圓角圖示方塊、
/// 圓角卡片、藍色主要按鈕。品牌陶土色只留在 App 圖示。
enum Palette {
    static let canvas = dynamic(light: 0xF4F5F7, dark: 0x14171D)
    static let blueTop = Color(hex: 0x3B82F6)
    static let blueBottom = Color(hex: 0x2563EB)
    static let accent = blueTop
    static let green = Color(hex: 0x30D158)
    static let orange = Color(hex: 0xFF9F0A)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    static let cardFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.05) : .white })
    static let cardStroke = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.06) })
    static let trackFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.04) : UIColor(white: 0, alpha: 0.04) })
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

/// 底色＋頂部中央淡藍光暈。
struct CanvasBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Palette.canvas
            RadialGradient(colors: [scheme == .dark ? Color(hex: 0x2A3B5C).opacity(0.25) : Color(hex: 0x3B82F6).opacity(0.10), .clear],
                           center: .top, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

/// 彩色圓角圖示方塊（iOS 30pt、圓角 26%）。
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 30
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 固定配色（STYLE.md）。
enum TileStyle {
    static let all = (symbol: "photo.on.rectangle", color: Color(hex: 0x0A84FF))
    static let favorites = (symbol: "heart.fill", color: Color(hex: 0xFF375F))
    static let dynamic = (symbol: "sun.max.fill", color: Color(hex: 0xFF9F0A))
    static let settings = (symbol: "gearshape.fill", color: Color(hex: 0x8E8E93))

    static func category(_ name: String) -> (symbol: String, color: Color) {
        switch name {
        case "自然": return ("leaf.fill", Color(hex: 0x30D158))
        case "極簡": return ("square", Color(hex: 0x8E8E93))
        case "抽象": return ("scribble.variable", Color(hex: 0x7D5CFF))
        case "插畫": return ("paintbrush.pointed.fill", Color(hex: 0xFF9F0A))
        case "宇宙": return ("sparkles", Color(hex: 0x5E5CE6))
        case "水彩": return ("paintpalette.fill", Color(hex: 0x40C8E0))
        case "建築": return ("building.columns.fill", Color(hex: 0xC9A26B))
        case "動畫": return ("film.fill", Color(hex: 0xFF6482))
        default: return ("photo", Color(hex: 0x636366))
        }
    }

    static func filter(_ f: GalleryFilter) -> (symbol: String, color: Color) {
        switch f {
        case .all: return all
        case .favorites: return favorites
        case .category(let name): return category(name)
        }
    }
}

/// 藥丸標籤：分類色填色、白字 13pt semibold。
struct Pill: View {
    let text: String
    let color: Color
    var size: CGFloat = 13
    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, size * 0.6).padding(.vertical, size * 0.2)
            .background(Capsule().fill(color))
    }
}

/// 區塊標題 22pt semibold ＋ 右邊藥丸。
struct SectionTitle: View {
    let title: String
    var pill: String?
    var color: Color = Palette.accent
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 22, weight: .semibold))
            if let pill { Pill(text: pill, color: color) }
            Spacer(minLength: 0)
        }
    }
}

struct CardModifier: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.cardFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Palette.cardStroke, lineWidth: 1))
    }
}

extension View {
    func card(radius: CGFloat = 16) -> some View { modifier(CardModifier(radius: radius)) }
}

/// 藍色漸層膠囊、白字 semibold。
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(Capsule().fill(LinearGradient(colors: [Palette.blueTop, Palette.blueBottom], startPoint: .top, endPoint: .bottom)))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// 次要膠囊按鈕。
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09)))
    }
}

/// 斜線紋（分類分布長條中「之前的」部分）。
struct StripedFill: View {
    let color: Color
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.22)))
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 6
            }
            context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1.4)
        }
    }
}

/// 從檔案載入縮圖並置中裁成格子比例。
struct ThumbnailView: View {
    let url: URL
    var maxPixel: CGFloat = 700
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.trackFill
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                } else {
                    ProgressView()
                }
            }
        }
        .task(id: url) {
            let url = url, maxPixel = maxPixel
            let cg = await Task.detached { ImageProcessing.thumbnail(at: url, maxPixel: maxPixel) }.value
            image = cg.map { UIImage(cgImage: $0) }
        }
    }
}

/// 只在 Debug 有作用的截圖用啟動參數（Release 一律 false）。
enum DebugLaunch {
    static var scrollToBottom: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "UTUVOScrollBottom")
        #else
        return false
        #endif
    }
}
