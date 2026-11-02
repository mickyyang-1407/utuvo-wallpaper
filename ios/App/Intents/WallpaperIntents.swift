import AppIntents
import Foundation
import UniformTypeIdentifiers

struct IntentFailure: LocalizedError {
    var errorDescription: String? { L("目前沒有可用的桌布。請先打開 UTUVO Wallpaper。") }
}

/// 「取得目前桌布」：只從已存在的檔案挑一張（不連網、不生圖），回傳 JPEG。
struct GetCurrentWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "取得目前桌布"
    static var description = IntentDescription("回傳 UTUVO Wallpaper 現在應該使用的桌布圖片，接到「設定背景圖片」動作。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let url = try CurrentWallpaper.resolve() else { throw IntentFailure() }
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: .jpeg))
    }
}

/// 「下一張桌布」：推進輪換一格並回傳圖片。
struct NextWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "下一張桌布"
    static var description = IntentDescription("跳到輪換中的下一張桌布並回傳圖片（會取消釘選）。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let url = try CurrentWallpaper.advance() else { throw IntentFailure() }
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: .jpeg))
    }
}

/// 「上一張桌布」：退回輪換一格並回傳圖片。
struct PreviousWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "上一張桌布"
    static var description = IntentDescription("回到輪換中的上一張桌布並回傳圖片（會取消釘選）。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let url = try CurrentWallpaper.previous() else { throw IntentFailure() }
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: .jpeg))
    }
}

struct WallpaperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetCurrentWallpaperIntent(),
                    phrases: ["Get current wallpaper from \(.applicationName)",
                              "取得\(.applicationName)目前的桌布"],
                    shortTitle: "取得目前桌布", systemImageName: "photo")
        AppShortcut(intent: NextWallpaperIntent(),
                    phrases: ["Next wallpaper in \(.applicationName)",
                              "\(.applicationName)下一張桌布"],
                    shortTitle: "下一張桌布", systemImageName: "forward")
        AppShortcut(intent: PreviousWallpaperIntent(),
                    phrases: ["Previous wallpaper in \(.applicationName)",
                              "\(.applicationName)上一張桌布"],
                    shortTitle: "上一張桌布", systemImageName: "backward")
    }
}
