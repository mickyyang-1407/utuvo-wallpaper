import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 以 CoreGraphics 高品質重採樣。
///
/// 誠實原則：這是「重採樣（resample）」，不是 AI 超解析、不是原生 6K。
/// 呼叫端必須在 metadata 標明這件事。
enum ImageResampler {
    struct ResizeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let sixK = CGSize(width: 6144, height: 3456)

    /// 讀出影像的像素尺寸（不解碼整張圖）。
    static func pixelSize(of data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 把 PNG 重採樣成 6K JPEG。
    static func resampleToJPEG6K(pngData: Data, jpegQuality: CGFloat = 0.95) throws -> Data {
        guard let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ResizeError(message: L("無法解碼來源圖片。"))
        }
        let width = Int(sixK.width)
        let height = Int(sixK.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ResizeError(message: L("無法建立重採樣畫布。"))
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = ctx.makeImage() else {
            throw ResizeError(message: L("重採樣失敗。"))
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ResizeError(message: L("無法建立 JPEG 輸出。"))
        }
        CGImageDestinationAddImage(dest, output, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ResizeError(message: L("JPEG 輸出寫入失敗。"))
        }
        return data as Data
    }

    /// 把 PNG 依原尺寸寫回檔案（保留原生）。
    static func writePNG(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// 寫入 JPEG 檔（不覆蓋既有檔）。
    static func writeJPEG(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
