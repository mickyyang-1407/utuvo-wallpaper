import Foundation

/// App container 的 Application Support/`UTUVO Wallpaper/`。
struct AppPaths: Sendable {
    let root: URL

    static let shared = AppPaths(root: {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("UTUVO Wallpaper", isDirectory: true)
    }())

    var wallpapers: URL { root.appendingPathComponent("wallpapers", isDirectory: true) }
    var originals: URL { root.appendingPathComponent("originals", isDirectory: true) }
    var dynamic: URL { root.appendingPathComponent("dynamic", isDirectory: true) }
    var demoCache: URL { root.appendingPathComponent("demo-cache", isDirectory: true) }
    var currentScenePointer: URL { dynamic.appendingPathComponent("current.json") }

    /// 建立資料夾；originals 不進 iCloud／裝置備份（體積大、可重新生成）。
    func prepare() {
        let fm = FileManager.default
        for dir in [wallpapers, originals, dynamic, demoCache] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        Self.excludeFromBackup(originals)
        Self.excludeFromBackup(demoCache)
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    /// 本機日期字串（批次檔名用）。
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 已用空間（bytes）。
    func usedBytes() -> Int {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
