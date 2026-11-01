import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum DynamicPhase: String, CaseIterable, Identifiable {
    case dawn, day, dusk, night
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dawn: return L("清晨")
        case .day: return L("白天")
        case .dusk: return L("黃昏")
        case .night: return L("夜晚")
        }
    }
    var time: String {
        switch self {
        case .dawn: return "06:00"
        case .day: return "09:00"
        case .dusk: return "18:00"
        case .night: return "21:00"
        }
    }
    var startHour: Int {
        switch self {
        case .dawn: return 6
        case .day: return 9
        case .dusk: return 18
        case .night: return 21
        }
    }
    var symbol: String {
        switch self {
        case .dawn: return "sunrise"
        case .day: return "sun.max"
        case .dusk: return "sunset"
        case .night: return "moon.stars"
        }
    }
    /// 結束時刻（下一個時段的開始）。
    var endHour: Int {
        switch self {
        case .dawn: return 9
        case .day: return 18
        case .dusk: return 21
        case .night: return 6
        }
    }
    var range: String { String(format: "%02d:00–%02d:00", startHour, endHour) }

    /// 24 小時時間軸的色段（小時，0–24）。夜晚跨午夜拆成頭尾兩段。
    static var timelineSegments: [(phase: DynamicPhase, start: Int, end: Int)] {
        [(.night, 0, 6), (.dawn, 6, 9), (.day, 9, 18), (.dusk, 18, 21), (.night, 21, 24)]
    }

    /// 一天中的位置（0…1），給「現在」指示線。
    static func dayFraction(at date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 1440
    }

    static func current(at date: Date) -> Self {
        switch Calendar.current.component(.hour, from: date) {
        case 6..<9: return .dawn
        case 9..<18: return .day
        case 18..<21: return .dusk
        default: return .night
        }
    }
}

/// One original scene, four aligned lighting variants. No network or credentials.
enum DynamicScene {
    static var title: String { GeneratedScene.load()?.prompt ?? L("山稜的一天") }

    /// Scene descriptions are full prompts; show the first clause as the name and keep the rest in tooltips.
    static func shortTitle(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators: Set<Character> = ["，", "、", "；", "。", ",", ";", "."]
        guard let cut = trimmed.firstIndex(where: { separators.contains($0) }) else { return trimmed }
        let head = String(trimmed[..<cut]).trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? trimmed : head
    }
    static var directory: URL {
        if let scene = GeneratedScene.load() { return scene.directory }
        return builtInDirectory
    }
    /// 內建示範「山稜的一天」所在位置（資料夾 → App 旁 → bundle 示範，取第一個四張都在的）。
    static var builtInDirectory: URL {
        let relative = "dynamic/mountain-hours"
        var candidates = [LabPaths.deliveryRoot.appendingPathComponent(relative, isDirectory: true)]
        if let adjacent = LabPaths.adjacentDataRoot { candidates.append(adjacent.appendingPathComponent(relative, isDirectory: true)) }
        if let demo = LabPaths.bundledDemo { candidates.append(demo.appendingPathComponent(relative, isDirectory: true)) }
        return candidates.first { directory in
            DynamicPhase.allCases.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.rawValue + ".jpg").path) }
        } ?? candidates[0]
    }
    static var resolution: String {
        guard let data = try? Data(contentsOf: imageURL(.day)), let size = ImageResampler.pixelSize(of: data) else { return L("尚無圖片") }
        return "\(Int(size.width)) × \(Int(size.height))"
    }
    static var heicURL: URL { directory.appendingPathComponent("mountain-hours.heic") }
    static func imageURL(_ phase: DynamicPhase) -> URL {
        directory.appendingPathComponent(phase.rawValue + ".jpg")
    }
    static var isReady: Bool {
        DynamicPhase.allCases.allSatisfy { FileManager.default.fileExists(atPath: imageURL($0).path) }
    }
    static var hasExport: Bool { FileManager.default.fileExists(atPath: heicURL.path) }

    /// h24 is an observed macOS format, not an Apple-documented schema.
    /// Image order: dawn=0, day=1, dusk=2, night=3. Midnight repeats night.
    static var schedule: [[String: Any]] {
        [["t": 0.0, "i": 3], ["t": 6.0 / 24, "i": 0],
         ["t": 9.0 / 24, "i": 1], ["t": 18.0 / 24, "i": 2],
         ["t": 21.0 / 24, "i": 3]]
    }

    static func export(to destination: URL, directory: URL = DynamicScene.directory) throws {
        func imageURL(_ phase: DynamicPhase) -> URL { directory.appendingPathComponent(phase.rawValue + ".jpg") }
        guard DynamicPhase.allCases.allSatisfy({ FileManager.default.fileExists(atPath: imageURL($0).path) }) else { throw SceneError(message: L("四個時段的圖片尚未備齊。")) }
        let plist: [String: Any] = ["ti": schedule, "ap": ["l": 1, "d": 3]]
        let encoded = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .base64EncodedString()
        let namespace = "http://ns.apple.com/namespace/1.0/" as CFString
        let prefix = "apple_desktop" as CFString
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix, nil),
              let tag = CGImageMetadataTagCreate(namespace, prefix, "h24" as CFString, .string, encoded as CFString),
              CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:h24" as CFString, tag) else {
            throw SceneError(message: L("無法建立動態桌布的時段資料。"))
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".dynamic-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.heic.identifier as CFString, 4, nil) else {
            throw SceneError(message: L("此 Mac 無法建立 HEIC 圖片。"))
        }
        let expected = ImageResampler.pixelSize(of: try Data(contentsOf: imageURL(.day)))
        let options = [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        for (index, phase) in DynamicPhase.allCases.enumerated() {
            guard let source = CGImageSourceCreateWithURL(imageURL(phase) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == Int(expected?.width ?? 0), image.height == Int(expected?.height ?? 0) else {
                throw SceneError(message: L("\(phase.title)圖片無法讀取或四時段尺寸不同。"))
            }
            if index == 0 {
                CGImageDestinationAddImageAndMetadata(output, image, metadata, options)
            } else {
                CGImageDestinationAddImage(output, image, options)
            }
        }
        guard CGImageDestinationFinalize(output) else { throw SceneError(message: L("HEIC 打包失敗。")) }
        // Refuse silent replacement from the CLI. The UI exports the existing package via NSSavePanel.
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SceneError(message: L("目的檔案已存在，請選另一個檔名。"))
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Read back the file actually written; do not infer native OS switching from this result.
    static func describe(_ url: URL) throws -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 4,
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, "apple_desktop:h24" as CFString),
              let data = Data(base64Encoded: value as String),
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let times = plist["ti"] as? [[String: Any]],
              NSArray(array: times).isEqual(to: schedule) else {
            throw SceneError(message: L("HEIC 時段資料讀回不符。"))
        }
        let expected = CGImageSourceCreateImageAtIndex(source, 0, nil)
        for index in 0..<4 {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), image.width == expected?.width, image.height == expected?.height else {
                throw SceneError(message: L("HEIC 第 \(index + 1) 張圖片讀回不符。"))
            }
        }
        return ["file": url.path, "frames": 4, "width": expected?.width ?? 0, "height": expected?.height ?? 0,
                "schedule": plist, "nativeSystemSwitchingTested": false]
    }

    struct SceneError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// 場景庫的一個場景：四張都在才算完整。
struct DynamicSceneEntry: Identifiable, Hashable {
    let directory: URL
    let title: String
    let created: Date?
    let isBuiltIn: Bool
    var id: String { directory.standardizedFileURL.path }

    func imageURL(_ phase: DynamicPhase) -> URL { directory.appendingPathComponent(phase.rawValue + ".jpg") }
    var heicURL: URL { directory.appendingPathComponent("mountain-hours.heic") }
    var hasExport: Bool { FileManager.default.fileExists(atPath: heicURL.path) }
    var resolution: String {
        guard let data = try? Data(contentsOf: imageURL(.day)), let size = ImageResampler.pixelSize(of: data) else { return L("尚無圖片") }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    static func isComplete(_ directory: URL) -> Bool {
        DynamicPhase.allCases.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.rawValue + ".jpg").path)
        }
    }
}

enum DynamicSceneLibrary {
    /// `dynamic/scenes/` 底下所有完整場景（新的在前），加上內建示範「山稜的一天」（若存在）。
    static func load(root: URL = LabPaths.deliveryRoot, builtIn: URL? = DynamicScene.builtInDirectory) -> [DynamicSceneEntry] {
        let fm = FileManager.default
        let scenesDir = root.appendingPathComponent("dynamic/scenes", isDirectory: true)
        let folders = (try? fm.contentsOfDirectory(at: scenesDir, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        var entries: [DynamicSceneEntry] = folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  DynamicSceneEntry.isComplete(folder) else { return nil }
            var prompt: String?
            if let data = try? Data(contentsOf: folder.appendingPathComponent("scene.json")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                prompt = object["prompt"] as? String
            }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            return DynamicSceneEntry(directory: folder, title: prompt ?? folder.lastPathComponent, created: created, isBuiltIn: false)
        }
        entries.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        if let builtIn, DynamicSceneEntry.isComplete(builtIn) {
            let created = (try? builtIn.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            entries.append(DynamicSceneEntry(directory: builtIn, title: L("山稜的一天"), created: created, isBuiltIn: true))
        }
        return entries
    }
}
