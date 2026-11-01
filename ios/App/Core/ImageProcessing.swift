import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 原生 PNG 保留；桌布＝依裝置原生像素 aspect-fill 置中裁切＋高品質重採樣的 JPEG（0.92）。
enum ImageProcessing {
    static let jpegQuality: CGFloat = 0.92

    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(source)
    }

    static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(source)
    }

    private static func pixelSize(_ source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    static func cropToJPEG(imageData: Data, target: CGSize) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw GenerationError.decoding }
        return try cropToJPEG(image: image, target: target)
    }

    static func cropToJPEG(fileURL: URL, target: CGSize) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw GenerationError.decoding }
        return try cropToJPEG(image: image, target: target)
    }

    static func cropToJPEG(image: CGImage, target: CGSize) throws -> Data {
        let width = Int(target.width), height = Int(target.height)
        guard width > 0, height > 0 else { throw GenerationError.decoding }
        let rect = CropMath.aspectFillSourceRect(source: CGSize(width: image.width, height: image.height), target: target)
        guard let cropped = image.cropping(to: rect),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw GenerationError.decoding }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw GenerationError.decoding }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw GenerationError.writeFailed
        }
        CGImageDestinationAddImage(dest, output, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw GenerationError.writeFailed }
        return data as Data
    }

    static func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { throw GenerationError.writeFailed }
    }

    /// 縮圖（不落地）。
    static func thumbnail(at url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
