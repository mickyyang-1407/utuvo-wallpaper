import CoreGraphics
import Foundation

/// 一張桌布：生成的（wallpapers/*.jpg）或內附示範圖。
struct WallpaperItem: Identifiable, Hashable, Sendable {
    let id: String          // 生成：檔名；示範：demo:<檔名>
    let url: URL            // 顯示用來源（示範圖是 16:9 原檔，顯示時置中裁切）
    let isDemo: Bool
    let modified: Date
    var category: String { WallpaperCategory.category(forFileName: isDemo ? String(id.dropFirst(5)) : id) }
}

enum DemoAssets {
    static let wallpaperNames = ["paper-landscape-demo-5k.jpg"]

    static func wallpapers(bundle: Bundle = .main) -> [WallpaperItem] {
        wallpaperNames.compactMap { name in
            let url = URL(fileURLWithPath: name)
            guard let found = bundle.url(forResource: url.deletingPathExtension().lastPathComponent,
                                         withExtension: url.pathExtension) else { return nil }
            return WallpaperItem(id: "demo:" + name, url: found, isDemo: true, modified: .distantPast)
        }
    }

    static func phaseURL(_ phase: DayPhase, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: phase.rawValue, withExtension: "jpg")
    }
}

enum WallpaperLibrary {
    /// 生成的桌布（新的在前）＋示範圖（最後）。
    static func load(paths: AppPaths, bundle: Bundle = .main) -> [WallpaperItem] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: paths.wallpapers, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var generated: [WallpaperItem] = []
        for url in entries where ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified: Date = values?.contentModificationDate ?? .distantPast
            generated.append(WallpaperItem(id: url.lastPathComponent, url: url, isDemo: false, modified: modified))
        }
        generated.sort { lhs, rhs in
            if lhs.modified == rhs.modified { return lhs.id < rhs.id }
            return lhs.modified > rhs.modified
        }
        return generated + DemoAssets.wallpapers(bundle: bundle)
    }

    static func filter(_ items: [WallpaperItem], by filter: GalleryFilter, favorites: Set<String>) -> [WallpaperItem] {
        switch filter {
        case .all: return items
        case .favorites: return items.filter { favorites.contains($0.id) }
        case .category(let name): return items.filter { $0.category == name }
        }
    }

    /// 已裁成裝置尺寸的 JPEG（生成圖本身就是；示範圖第一次用時裁切並快取）。
    static func deviceJPEG(for item: WallpaperItem, paths: AppPaths, target: CGSize) throws -> URL {
        guard item.isDemo else { return item.url }
        return try cachedCrop(source: item.url, name: "wall-" + String(item.id.dropFirst(5)), paths: paths, target: target)
    }

    static func cachedCrop(source: URL, name: String, paths: AppPaths, target: CGSize) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let out = paths.demoCache.appendingPathComponent("\(base)-\(Int(target.width))x\(Int(target.height)).jpg")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let jpeg = try ImageProcessing.cropToJPEG(fileURL: source, target: target)
        try ImageProcessing.write(jpeg, to: out)
        AppPaths.excludeFromBackup(paths.demoCache)
        return out
    }

    /// 日夜場景四時段的裝置尺寸 JPEG。
    static func scenePhaseJPEG(sceneID: String, phase: DayPhase, paths: AppPaths, target: CGSize,
                               bundle: Bundle = .main) throws -> URL? {
        if sceneID == "demo" {
            guard let source = DemoAssets.phaseURL(phase, bundle: bundle) else { return nil }
            return try cachedCrop(source: source, name: "hours-" + phase.rawValue, paths: paths, target: target)
        }
        let url = paths.dynamic.appendingPathComponent(sceneID).appendingPathComponent(phase.rawValue + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func delete(_ item: WallpaperItem, paths: AppPaths) {
        guard !item.isDemo else { return }
        try? FileManager.default.removeItem(at: item.url)
        let original = paths.originals.appendingPathComponent((item.id as NSString).deletingPathExtension + ".png")
        try? FileManager.default.removeItem(at: original)
    }
}

/// App Intent 與 App 共用：決定並取出「目前桌布」檔案（不連網、不生圖）。
enum CurrentWallpaper {
    /// 「取得目前桌布」：日夜 → 釘選 → 輪換（換了小時才前進一格）。
    static func resolve(at date: Date = Date(), paths: AppPaths = .shared, prefs: Preferences = Preferences(),
                        bundle: Bundle = .main, target: CGSize = DeviceScreen.nativePixels,
                        calendar: Calendar = .current) throws -> URL? {
        let items = WallpaperLibrary.load(paths: paths, bundle: bundle)
        if prefs.dynamicEnabled {
            let phase = DayPhase.current(at: date, calendar: calendar, defaults: prefs.defaults)
            if let url = try WallpaperLibrary.scenePhaseJPEG(sceneID: prefs.dynamicSceneID, phase: phase,
                                                             paths: paths, target: target, bundle: bundle) { return url }
            // 場景檔不見了：退回一般規則
        }
        return try pick(at: date, items: items, prefs: prefs, force: false, paths: paths, target: target, calendar: calendar)
    }

    /// 「下一張桌布」：清除釘選、強制推進輪換一格（不受日夜模式影響）。
    static func advance(at date: Date = Date(), paths: AppPaths = .shared, prefs: Preferences = Preferences(),
                        bundle: Bundle = .main, target: CGSize = DeviceScreen.nativePixels,
                        calendar: Calendar = .current) throws -> URL? {
        prefs.pinnedID = nil
        let items = WallpaperLibrary.load(paths: paths, bundle: bundle)
        return try pick(at: date, items: items, prefs: prefs, force: true, paths: paths, target: target, calendar: calendar)
    }

    /// 「上一張桌布」：清除釘選、輪換退回一格。
    static func previous(at date: Date = Date(), paths: AppPaths = .shared, prefs: Preferences = Preferences(),
                         bundle: Bundle = .main, target: CGSize = DeviceScreen.nativePixels,
                         calendar: Calendar = .current) throws -> URL? {
        prefs.pinnedID = nil
        let items = WallpaperLibrary.load(paths: paths, bundle: bundle)
        return try pick(at: date, items: items, prefs: prefs, force: true, delta: -1, paths: paths, target: target, calendar: calendar)
    }

    private static func pick(at date: Date, items: [WallpaperItem], prefs: Preferences, force: Bool, delta: Int = 1,
                             paths: AppPaths, target: CGSize, calendar: Calendar) throws -> URL? {
        let result = WallpaperSelection.choose(
            at: date, dynamicPhaseIDs: nil, pinnedID: prefs.pinnedID, available: items.map(\.id),
            favorites: prefs.favorites, favoritesOnly: prefs.favoritesOnly, state: prefs.rotation,
            force: force, delta: delta, frequency: prefs.rotationFrequency, calendar: calendar)
        prefs.rotation = result.state
        guard let choice = result.choice, let item = items.first(where: { $0.id == choice.id }) else { return nil }
        return try WallpaperLibrary.deviceJPEG(for: item, paths: paths, target: target)
    }
}
