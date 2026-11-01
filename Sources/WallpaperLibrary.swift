import Foundation
import ImageIO
import CoreGraphics

/// 掃描桌布資料夾。
///
/// 不依賴 metadata 檔：直接讀圖檔本身的像素尺寸，
/// 若旁邊有 `*.provenance.json` 則以它為準（可標示「AI 放大」等來源）。
enum WallpaperLibrary {
    static let supportedExtensions = ["jpg", "jpeg", "png"]

    static func load() -> [Wallpaper] {
        var items: [Wallpaper] = []
        var seenIDs = Set<String>()
        for dir in LabPaths.scanDirectories() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries {
                guard let item = makeWallpaper(from: url) else { continue }
                guard seenIDs.insert(item.id).inserted else { continue }
                items.append(item)
            }
        }
        // 排序：依檔名
        items.sort { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return items
    }

    /// 從檔案建立 Wallpaper；讀不出圖片就回傳 nil（呼叫端顯示空狀態）。
    static func makeWallpaper(from url: URL) -> Wallpaper? {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let origin = resolveOrigin(for: url, width: width, height: height)
        return Wallpaper(id: url.lastPathComponent, url: url,
                         pixelWidth: width, pixelHeight: height, origin: origin)
    }

    /// 判定來源標記：sidecar 優先，其次用尺寸與檔名規則。
    static func resolveOrigin(for url: URL, width: Int, height: Int) -> ImageOrigin {
        let sidecar = url.deletingPathExtension().appendingPathExtension("provenance.json")
        if let data = try? Data(contentsOf: sidecar),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = object["origin"] as? String {
            switch raw {
            case "native": return .native
            case "resampled": return .resampled
            case "ai-upscaled": return .aiUpscaled
            default: break
            }
        }
        let name = url.lastPathComponent.lowercased()
        if name.contains("upscaled") || name.contains("ai-upscale") { return .aiUpscaled }
        if name.contains("-5k") || name.contains("resample") { return .resampled }
        if width == 5120 && height == 2880 { return .resampled }
        if width == 3840 && height == 2160 { return .native }
        if url.deletingLastPathComponent().lastPathComponent == "originals" { return .native }
        return .unknown
    }

    static let otherCategory = "其他"
    /// 早期示範圖沒有對應的範本 id。
    private static let legacyCategories = ["alpine-dawn": "自然", "paper-landscape": "極簡"]

    /// 分類取自檔名開頭的範本 id（生成時固定寫入），不需另存 metadata。
    static func category(forFileName name: String) -> String {
        let lowered = name.lowercased()
        let matches = PromptTemplate.shared.map { ($0.id, $0.category) } + legacyCategories.map { ($0.key, $0.value) }
        return matches.filter { lowered == $0.0 || lowered.hasPrefix($0.0 + "-") || lowered.hasPrefix($0.0 + ".") }
            .max { $0.0.count < $1.0.count }?.1 ?? otherCategory
    }

    /// 範本出現順序，「其他」放最後。
    static var categoryOrder: [String] {
        var seen = Set<String>()
        return PromptTemplate.shared.map(\.category).filter { seen.insert($0).inserted } + [otherCategory]
    }

    /// 產生一張預覽用的小圖（不落地到磁碟）。
    static func thumbnail(from url: URL, maxPixel: CGFloat = 320) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
