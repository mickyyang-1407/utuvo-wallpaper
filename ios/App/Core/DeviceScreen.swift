import CoreGraphics
import UIKit

/// 目前裝置螢幕的原生像素（直式）。前景時從 window scene 取；
/// 背景／Intent 沒有 scene 時用上次記住的值。
enum DeviceScreen {
    private static let key = "deviceNativePixels"
    static let fallback = CGSize(width: 1320, height: 2868)

    @MainActor
    static func refresh() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let screen = scenes.first?.screen else { return }
        let size = CropMath.portraitPixels(screen.nativeBounds.size)
        guard size.width > 0 else { return }
        UserDefaults.standard.set([Double(size.width), Double(size.height)], forKey: key)
    }

    static var nativePixels: CGSize {
        if let pair = UserDefaults.standard.array(forKey: key) as? [Double], pair.count == 2, pair[0] > 0 {
            return CGSize(width: pair[0], height: pair[1])
        }
        return fallback
    }
}
