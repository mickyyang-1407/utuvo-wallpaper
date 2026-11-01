import Foundation

/// 使用者自訂標籤。存在資料根目錄的 `tags.json`：
/// `{"tags":[{"name":String,"color":"#RRGGBB"}],"assignments":{wallpaperID:[name]}}`
///
/// - 寫入一律原子（tmp＋rename）。
/// - 讀不到 → 空集合；壞檔 → 改名 `tags.corrupt-<時間>.json` 保留，再從空集合開始，絕不覆蓋壞檔。
struct WallpaperTag: Codable, Hashable, Identifiable {
    var name: String
    var color: String
    var id: String { name }
}

struct TagDocument: Codable, Equatable {
    var tags: [WallpaperTag] = []
    var assignments: [String: [String]] = [:]
}

final class TagStore {
    /// 沿用 STYLE.md 的分類色，給新增標籤時挑。
    static let palette = ["#0A84FF", "#FF375F", "#FF9F0A", "#30D158", "#7D5CFF", "#5E5CE6", "#40C8E0", "#C9A26B"]

    let url: URL
    private(set) var document = TagDocument()
    /// 最近一次載入時若發現壞檔，被改名到的位置（給 UI／測試讀）。
    private(set) var recoveredCorruptURL: URL?

    init(root: URL) {
        url = root.appendingPathComponent("tags.json")
        load()
    }

    func load() {
        recoveredCorruptURL = nil
        guard let data = try? Data(contentsOf: url) else { document = TagDocument(); return }
        if let decoded = try? JSONDecoder().decode(TagDocument.self, from: data) {
            document = TagStore.normalized(decoded)
            return
        }
        // 壞檔：先改名保留，再從空集合開始。
        let stamp = TagStore.stampFormatter.string(from: Date())
        var target = url.deletingLastPathComponent().appendingPathComponent("tags.corrupt-\(stamp).json")
        var suffix = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("tags.corrupt-\(stamp)-\(suffix).json")
            suffix += 1
        }
        if (try? FileManager.default.moveItem(at: url, to: target)) != nil { recoveredCorruptURL = target }
        document = TagDocument()
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// 去掉指向不存在標籤的指派、重複名稱與空陣列。
    static func normalized(_ input: TagDocument) -> TagDocument {
        var seen = Set<String>()
        let tags = input.tags.filter { !$0.name.isEmpty && seen.insert($0.name).inserted }
        var assignments: [String: [String]] = [:]
        for (id, names) in input.assignments {
            var unique = Set<String>()
            let kept = names.filter { seen.contains($0) && unique.insert($0).inserted }
            if !kept.isEmpty { assignments[id] = kept }
        }
        return TagDocument(tags: tags, assignments: assignments)
    }

    // MARK: - 查詢

    var tags: [WallpaperTag] { document.tags }

    func tag(named name: String) -> WallpaperTag? { document.tags.first { $0.name == name } }

    func tags(for wallpaperID: String) -> [WallpaperTag] {
        let names = Set(document.assignments[wallpaperID] ?? [])
        return document.tags.filter { names.contains($0.name) }
    }

    func ids(with name: String) -> Set<String> {
        Set(document.assignments.compactMap { $0.value.contains(name) ? $0.key : nil })
    }

    func count(for name: String, among ids: Set<String>) -> Int { self.ids(with: name).intersection(ids).count }

    /// 所有 ids 都有這個標籤（給右鍵選單打勾）。
    func allHave(_ name: String, ids: Set<String>) -> Bool {
        !ids.isEmpty && ids.allSatisfy { document.assignments[$0]?.contains(name) == true }
    }

    // MARK: - 修改（每個都立即原子寫入；失敗丟錯、記憶體不變）

    enum TagError: LocalizedError, Equatable {
        case emptyName, duplicateName, notFound
        var errorDescription: String? {
            switch self {
            case .emptyName: return L("標籤名稱不能是空白。")
            case .duplicateName: return L("已經有同名的標籤。")
            case .notFound: return L("找不到這個標籤。")
            }
        }
    }

    func addTag(name rawName: String, color: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TagError.emptyName }
        guard tag(named: name) == nil else { throw TagError.duplicateName }
        var next = document
        next.tags.append(WallpaperTag(name: name, color: color))
        try commit(next)
    }

    func renameTag(_ old: String, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TagError.emptyName }
        guard let index = document.tags.firstIndex(where: { $0.name == old }) else { throw TagError.notFound }
        if name == old { return }
        guard tag(named: name) == nil else { throw TagError.duplicateName }
        var next = document
        next.tags[index].name = name
        next.assignments = next.assignments.mapValues { $0.map { $0 == old ? name : $0 } }
        try commit(next)
    }

    func recolorTag(_ name: String, color: String) throws {
        guard let index = document.tags.firstIndex(where: { $0.name == name }) else { throw TagError.notFound }
        var next = document
        next.tags[index].color = color
        try commit(next)
    }

    /// 只刪標籤本身與它的指派，不碰圖片。
    func deleteTag(_ name: String) throws {
        guard tag(named: name) != nil else { throw TagError.notFound }
        var next = document
        next.tags.removeAll { $0.name == name }
        next.assignments = next.assignments.mapValues { $0.filter { $0 != name } }
        try commit(next)
    }

    /// 對多張圖一次加上或移除。
    func set(_ name: String, assigned: Bool, for ids: Set<String>) throws {
        guard tag(named: name) != nil else { throw TagError.notFound }
        var next = document
        for id in ids {
            var names = next.assignments[id] ?? []
            if assigned { if !names.contains(name) { names.append(name) } }
            else { names.removeAll { $0 == name } }
            next.assignments[id] = names
        }
        try commit(next)
    }

    /// 圖被刪除時一併移除其指派。
    func removeAssignments(for ids: Set<String>) throws {
        guard ids.contains(where: { document.assignments[$0] != nil }) else { return }
        var next = document
        for id in ids { next.assignments[id] = nil }
        try commit(next)
    }

    private func commit(_ candidate: TagDocument) throws {
        let next = TagStore.normalized(candidate)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tags.\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
        document = next
    }
}
