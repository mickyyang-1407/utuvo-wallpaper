import CoreGraphics
import Foundation

/// aspect-fill 置中裁切的數學（純函式，方便測試）。
enum CropMath {
    /// 在來源像素座標中，回傳要取用的置中矩形（整數像素）。
    static func aspectFillSourceRect(source: CGSize, target: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .zero }
        let sourceAspect = source.width / source.height
        let targetAspect = target.width / target.height
        if sourceAspect > targetAspect {
            // 來源較寬：裁左右
            let width = (source.height * targetAspect).rounded()
            let x = ((source.width - width) / 2).rounded(.down)
            return CGRect(x: x, y: 0, width: width, height: source.height)
        } else {
            // 來源較高：裁上下
            let height = (source.width / targetAspect).rounded()
            let y = ((source.height - height) / 2).rounded(.down)
            return CGRect(x: 0, y: y, width: source.width, height: height)
        }
    }

    /// 輸出尺寸固定為裝置原生像素（直式：寬 < 高）。
    static func portraitPixels(_ size: CGSize) -> CGSize {
        CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
    }

    static func label(_ size: CGSize) -> String { "\(Int(size.width)) × \(Int(size.height))" }
}
