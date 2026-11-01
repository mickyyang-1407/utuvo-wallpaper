import AppKit
import CoreGraphics

// MARK: - 桌面套用抽象

/// 桌布套用的抽象。正式環境用 `DesktopController`；自我測試注入假實作，不碰真的桌面。
@MainActor
protocol DesktopApplying: AnyObject {
    /// 逐螢幕設定桌布，回傳每顆螢幕的結果。
    func setWallpaperOnAllScreens(_ url: URL) async -> [ScreenApplyResult]
    func setWallpaper(_ url: URL, onDisplayID: UInt32?) async -> [ScreenApplyResult]
    /// 目前接著的螢幕（每顆螢幕輪換不同張時用）。
    func displayIDs() -> [UInt32]
}

// MARK: - 桌面控制

/// 設定與讀回目前桌面。
///
/// 誠實範圍：
/// - 只作用在「目前的 Spaces」。macOS 的桌布在不同 Space 之間的行為由系統決定，
///   本工具不宣稱已套用到所有 Space。
/// - 讀回是「逐螢幕」做的：先記錄每顆螢幕原本的桌布路徑，再設定、再讀回比對。
/// - 只用 `NSWorkspace` 的路徑讀回驗證，**不擷取畫面**：不記錄使用者其他 App 的畫面，
///   因此這裡沒有「像素級」證據，只有「系統回報的桌布路徑」證據。
@MainActor
final class DesktopController: DesktopApplying {
    struct ScreenSnapshot: Codable {
        let index: Int
        let name: String
        let displayID: UInt32
        let frame: String
        let pixelWidth: Int
        let pixelHeight: Int
        let backingScaleFactor: Double
        let currentWallpaper: String?
    }

    static func currentScreens() -> [NSScreen] { NSScreen.screens }

    /// 讀取某顆螢幕目前的桌布網址（可能是 nil，例如系統內建桌布走的是另一套機制）。
    func wallpaperURL(for screen: NSScreen) -> URL? {
        NSWorkspace.shared.desktopImageURL(for: screen)
    }

    /// 讀取某顆螢幕目前的桌布設定（縮放模式／是否裁切），用來還原使用者原本的選擇。
    ///
    /// 系統會回傳實際的選項值（例如縮放模式），所以還原時可以原樣送回去，
    /// 不會把使用者原本的設定改成預設值。
    static func currentImageOptions(for screen: NSScreen) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
    }

    /// 把設定轉成可讀文字（給 JSON 輸出與紀錄用）。
    static func describe(_ options: [NSWorkspace.DesktopImageOptionKey: Any]) -> String {
        var names: [String] = []
        if options[.allowClipping] != nil { names.append("allowClipping") }
        if let scaling = options[.imageScaling] as? NSNumber,
           let mode = NSImageScaling(rawValue: UInt(scaling.intValue)) {
            names.append("imageScaling=\(mode)")
        } else if options[.imageScaling] != nil {
            names.append("imageScaling")
        }
        return names.isEmpty ? L("（系統預設）") : names.joined(separator: ", ")
    }

    /// 是否是系統內建／動態桌布。
    ///
    /// 這類桌布在 macOS 上回報的是 `DefaultDesktop.heic` 一類的路徑，
    /// 畫面內容其實不是那張圖；沒有擷取畫面就無法確認，只能保守跳過。
    static func isSystemDesktop(_ url: URL) -> Bool {
        let path = url.path
        if path.contains("/System/Library/Desktop Pictures/") { return true }
        if path.contains("/Library/Desktop Pictures/") { return true }
        return url.lastPathComponent.lowercased().hasPrefix("defaultdesktop")
    }

    /// 設定某顆螢幕的桌布。
    func setWallpaper(_ url: URL, on screen: NSScreen) throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true
        ]
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        LabLog.desktop.notice("wallpaper applied display=\(Self.displayID(of: screen), privacy: .public)")
    }

    /// 逐螢幕設定，回傳每顆螢幕的結果。
    ///
    /// 設定後先給系統一點時間把新桌布寫進設定，再讀回比對；
    /// 「設定成功但讀回不符」不算成功，會在結果裡標成 `readbackMatched = false`。
    @discardableResult
    func setWallpaperOnAllScreens(_ url: URL) async -> [ScreenApplyResult] {
        await setWallpaper(url, onDisplayID: nil)
    }

    /// nil 代表所有目前螢幕；指定的螢幕離線時回傳空結果，不擴大成全部套用。
    func setWallpaper(_ url: URL, onDisplayID target: UInt32?) async -> [ScreenApplyResult] {
        var results: [ScreenApplyResult] = []
        for (index, screen) in Self.currentScreens().enumerated() {
            if let target, Self.displayID(of: screen) != target { continue }
            var result = ScreenApplyResult(index: index,
                                           name: screen.localizedName,
                                           displayID: Int(Self.displayID(of: screen)),
                                           originalWallpaper: wallpaperURL(for: screen)?.path,
                                           applied: false,
                                           readbackMatched: false,
                                           error: nil)
            do {
                try setWallpaper(url, on: screen)
                result.applied = true
                // NSWorkspace 寫入與讀回可能不同步；限時等待，不重新送出設定。
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    result.readbackMatched = wallpaperURL(for: screen)?.standardizedFileURL == url.standardizedFileURL
                    if result.readbackMatched { break }
                }
            } catch {
                result.error = L("設定失敗：\(error.localizedDescription)")
            }
            results.append(result)
        }
        return results
    }

    func displayIDs() -> [UInt32] { Self.currentScreens().map { Self.displayID(of: $0) } }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value ?? 0
    }

    /// 目前所有螢幕的資訊（唯讀）。
    static func snapshots() -> [ScreenSnapshot] {
        currentScreens().enumerated().map { index, screen in
            let mode = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let modeInfo = CGDisplayCopyDisplayMode(CGDirectDisplayID(displayID))
            _ = mode
            return ScreenSnapshot(
                index: index,
                name: screen.localizedName,
                displayID: displayID,
                frame: NSStringFromRect(screen.frame),
                pixelWidth: modeInfo.map { $0.pixelWidth } ?? Int(screen.frame.width * screen.backingScaleFactor),
                pixelHeight: modeInfo.map { $0.pixelHeight } ?? Int(screen.frame.height * screen.backingScaleFactor),
                backingScaleFactor: Double(screen.backingScaleFactor),
                currentWallpaper: NSWorkspace.shared.desktopImageURL(for: screen)?.path
            )
        }
    }
}

// MARK: - 套用結果

struct ScreenApplyResult: Codable {
    let index: Int
    let name: String
    let displayID: Int
    let originalWallpaper: String?
    var applied: Bool
    var readbackMatched: Bool
    var error: String?
}
