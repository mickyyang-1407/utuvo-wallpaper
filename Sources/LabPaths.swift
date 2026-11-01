import Foundation

/// Per-user storage. The override is for isolated fixtures or an explicitly chosen portable folder.
enum LabPaths {
    static let appName = "UTUVO Wallpaper"
    static let dataDirectoryVariable = "UTUVO_WALLPAPER_DATA_DIR"

    static var overriddenDirectory: URL? {
        guard let value = getenv(dataDirectoryVariable) else { return nil }
        let path = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    static var deliveryRoot: URL {
        overriddenDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }
    static var wallpapersDir: URL { deliveryRoot.appendingPathComponent("wallpapers", isDirectory: true) }
    static var originalsDir: URL { deliveryRoot.appendingPathComponent("originals", isDirectory: true) }

    /// Read-only compatibility with the local trial's images. New files always use per-user storage.
    static var adjacentDataRoot: URL? {
        guard overriddenDirectory == nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.bundleURL.deletingLastPathComponent()
    }

    static var bundledDemo: URL? {
        guard overriddenDirectory == nil else { return nil }
        return Bundle.main.resourceURL?.appendingPathComponent("Demo", isDirectory: true)
    }

    static func scanDirectories() -> [URL] {
        var candidates = [wallpapersDir]
        if let adjacent = adjacentDataRoot { candidates.append(adjacent.appendingPathComponent("wallpapers", isDirectory: true)) }
        let hasImages = candidates.contains { directory in
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.contains { WallpaperLibrary.supportedExtensions.contains($0.pathExtension.lowercased()) }
        }
        if !hasImages, let demo = bundledDemo { candidates.append(demo.appendingPathComponent("wallpapers", isDirectory: true)) }
        var seen = Set<String>()
        return candidates.filter { directory in
            var isDirectory: ObjCBool = false
            return seen.insert(directory.standardizedFileURL.path).inserted &&
                FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
