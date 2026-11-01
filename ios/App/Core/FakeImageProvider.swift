#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 只在 Debug：截圖與模擬器開發用的假 provider（不連網）。
/// 啟動參數 `-UTUVOFakeProvider YES` 時，App 用它代替 OpenAI。
struct FakeImageProvider: ImageProvider {
    var size = CGSize(width: 432, height: 768)

    func generateImage(prompt: String) async throws -> Data {
        _ = try OpenAIImageProvider.validatePrompt(prompt)
        let seed = abs(prompt.hashValue)
        return Self.png(size: size, hue: Double(seed % 360) / 360, light: 1)
    }

    func relight(reference: Data, prompt: String) async throws -> Data {
        let light: Double = prompt.contains("night") ? 0.25 : prompt.contains("dawn") ? 0.8 : prompt.contains("sunset") ? 0.6 : 1
        let hue: Double = prompt.contains("night") ? 0.62 : prompt.contains("dawn") ? 0.95 : 0.07
        return Self.png(size: size, hue: hue, light: light)
    }

    static func png(size: CGSize, hue: Double, light: Double) -> Data {
        let w = Int(size.width), h = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ hh: Double, _ s: Double, _ b: Double) -> CGColor {
            let (r, g, bl) = hsb(hh, s, b)
            return CGColor(colorSpace: space, components: [r, g, bl, 1])!
        }
        let gradient = CGGradient(colorsSpace: space, colors: [color(hue, 0.35, 0.95 * light),
                                                               color(fmod(hue + 0.08, 1), 0.55, 0.55 * light)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        ctx.setFillColor(color(fmod(hue + 0.5, 1), 0.3, 0.85 * light))
        ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 5, width: w / 2, height: w / 2))
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private static func hsb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
#endif
