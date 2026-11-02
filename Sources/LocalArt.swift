import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 純色與漸層桌布：直接在本機畫，不送 AI、不花額度、瞬間完成，解析度隨要多大就多大。
/// 規格寫在提示詞欄位裡（`local:solid:#RRGGBB`、`local:gradient:#A,#B,#C|角度`），進度檔照存，續作一樣。
enum LocalArt {
    static let prefix = "local:"

    static func isLocal(_ prompt: String) -> Bool { prompt.hasPrefix(prefix) }

    /// 依規格畫一張 PNG；不是本機規格回 nil。
    static func render(_ spec: String, width: Int, height: Int) -> Data? {
        guard isLocal(spec), width > 0, height > 0 else { return nil }
        let body = spec.dropFirst(prefix.count)
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        switch parts[0] {
        case "solid":
            guard let color = color(parts[1], space: space) else { return nil }
            context.setFillColor(color)
            context.fill(rect)
            addGrain(context, width: width, height: height, strength: 0.012)
        case "gradient":
            let pieces = parts[1].split(separator: "|").map(String.init)
            let colors = pieces[0].split(separator: ",").compactMap { color(String($0), space: space) }
            guard colors.count >= 2 else { return nil }
            let angle = (pieces.count > 1 ? Double(pieces[1]) : nil) ?? 135
            let locations = (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
            guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return nil }
            let radians = angle * .pi / 180
            let half = hypot(Double(width), Double(height)) / 2
            let center = CGPoint(x: Double(width) / 2, y: Double(height) / 2)
            let delta = CGPoint(x: cos(radians) * half, y: sin(radians) * half)
            context.drawLinearGradient(gradient, start: CGPoint(x: center.x - delta.x, y: center.y - delta.y),
                                       end: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            // 一層柔光，讓畫面不像純粹的直線漸層。
            if let glow = CGGradient(colorsSpace: space, colors: [colors[colors.count / 2].copy(alpha: 0.45)!,
                                                                  colors[colors.count / 2].copy(alpha: 0)!] as CFArray,
                                     locations: [0, 1]) {
                context.drawRadialGradient(glow, startCenter: CGPoint(x: Double(width) * 0.68, y: Double(height) * 0.62), startRadius: 0,
                                           endCenter: CGPoint(x: Double(width) * 0.68, y: Double(height) * 0.62),
                                           endRadius: CGFloat(half * 0.9), options: [])
            }
            // 細顆粒：避免大面積漸層出現一條條色階。
            addGrain(context, width: width, height: height, strength: 0.025)
        default:
            return nil
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// "#RRGGBB" → 顏色。
    static func color(_ hex: String, space: CGColorSpace) -> CGColor? {
        let text = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        let components: [CGFloat] = [CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255,
                                     CGFloat(value & 0xFF) / 255, 1]
        return CGColor(colorSpace: space, components: components)
    }

    /// 固定種子的細小亮暗點（同一張每次畫都一樣）。
    private static func addGrain(_ context: CGContext, width: Int, height: Int, strength: CGFloat) {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        let step = max(2, min(width, height) / 900)
        context.setBlendMode(.overlay)
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let v = CGFloat((seed >> 33) & 0xFF) / 255
                context.setFillColor(gray: v, alpha: strength)
                context.fill(CGRect(x: x, y: y, width: step, height: step))
            }
        }
        context.setBlendMode(.normal)
    }
}
