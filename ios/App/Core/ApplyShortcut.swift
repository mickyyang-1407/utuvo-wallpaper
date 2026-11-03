import Foundation

/// iOS 不准 App 自己換桌布，只能叫「捷徑」的「設定背景圖片」。
/// 按「設為桌布」＝先固定這張，再用 x-callback 執行一個固定名字的捷徑，捷徑跑完回到 App。
enum ApplyShortcut {
    /// 捷徑名字：App 內附的捷徑檔就是這個名字，手動建立也要一字不差。
    static let name = "UTUVO Set Wallpaper"
    static let scheme = "utuvowallpaper"

    enum Outcome: Equatable { case done, cancelled, failed(String?) }

    static var runURL: URL {
        var c = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
        c.queryItems = [URLQueryItem(name: "name", value: name),
                        URLQueryItem(name: "x-success", value: "\(scheme)://shortcut/done"),
                        URLQueryItem(name: "x-cancel", value: "\(scheme)://shortcut/cancel"),
                        URLQueryItem(name: "x-error", value: "\(scheme)://shortcut/error")]
        return c.url!
    }

    /// 捷徑回呼；不是捷徑回呼的網址回傳 nil。
    static func outcome(of url: URL) -> Outcome? {
        guard url.scheme == scheme, url.host == "shortcut" else { return nil }
        switch url.path {
        case "/done": return .done
        case "/cancel": return .cancelled
        case "/error":
            let message = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "errorMessage" }?.value
            return .failed(message)
        default: return nil
        }
    }

    /// App 內附的捷徑檔（已簽署，任何人都能加入）。
    static var bundledFile: URL? { Bundle.main.url(forResource: name, withExtension: "shortcut") }
}

enum ShortcutSetupReason: Equatable, Identifiable {
    case firstTime
    case failed(String?)
    var id: String {
        switch self {
        case .firstTime: return "first"
        case .failed(let text): return "failed:\(text ?? "")"
        }
    }
}
