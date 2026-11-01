import Foundation

// MARK: - 解析度級距

enum ResolutionTier: String, CaseIterable, Hashable, Sendable {
    case sixK, fiveK, fourK, other

    /// 依寬度判斷：6K ≥ 6144、5K ≥ 5120、4K ≥ 3840，其餘為「其他」。
    static func tier(forWidth width: Int) -> ResolutionTier {
        if width >= 6144 { return .sixK }
        if width >= 5120 { return .fiveK }
        if width >= 3840 { return .fourK }
        return .other
    }

    var title: String {
        switch self {
        case .sixK: return "6K"
        case .fiveK: return "5K"
        case .fourK: return "4K"
        case .other: return L("其他")
        }
    }

    /// 只回傳有圖的級距與張數（固定順序 6K → 5K → 4K → 其他）。
    static func histogram(widths: [Int]) -> [(ResolutionTier, Int)] {
        var counts: [ResolutionTier: Int] = [:]
        for width in widths { counts[tier(forWidth: width), default: 0] += 1 }
        return allCases.compactMap { tier in counts[tier].map { (tier, $0) } }
    }
}

// MARK: - 多選

struct SelectionModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let command = SelectionModifiers(rawValue: 1)
    static let shift = SelectionModifiers(rawValue: 2)
    static let option = SelectionModifiers(rawValue: 4)
}

struct SelectionState: Equatable, Sendable {
    var ids: Set<String> = []
    /// Shift 範圍的起點（上次點的那張）。
    var anchor: String?
    /// 主要選取：給檢視器與設為桌布。
    var primary: String?
}

enum SelectionLogic {
    /// 點擊。`order` 是目前畫面順序。
    static func click(_ state: SelectionState, id: String, modifiers: SelectionModifiers, order: [String]) -> SelectionState {
        var next = state
        if modifiers.contains(.option) {
            // ⌥：把那張移出；若它是唯一選取就全部清空。
            next.ids.remove(id)
            if next.ids.isEmpty { return SelectionState() }
            if next.primary == id { next.primary = order.first { next.ids.contains($0) } }
            if next.anchor == id { next.anchor = next.primary }
            return next
        }
        if modifiers.contains(.shift), let anchor = state.anchor,
           let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let range = order[min(from, to)...max(from, to)]
            next.ids.formUnion(range)
            next.primary = id
            // 錨點不動，連續 Shift 都從同一張算起。
            return next
        }
        if modifiers.contains(.command) {
            if next.ids.contains(id) {
                next.ids.remove(id)
                if next.ids.isEmpty { return SelectionState() }
                if next.primary == id { next.primary = order.first { next.ids.contains($0) } }
                next.anchor = id
            } else {
                next.ids.insert(id)
                next.primary = id
                next.anchor = id
            }
            return next
        }
        return SelectionState(ids: [id], anchor: id, primary: id)
    }

    /// ⌘A：選取畫面上全部。
    static func selectAll(_ state: SelectionState, order: [String]) -> SelectionState {
        guard !order.isEmpty else { return SelectionState() }
        let primary = state.primary.flatMap { order.contains($0) ? $0 : nil } ?? order.first
        return SelectionState(ids: Set(order), anchor: state.anchor ?? primary, primary: primary)
    }

    /// 換側欄區段或搜尋文字後：選取裁成畫面上看得到的項目，不保留看不到的隱藏選取。
    static func restrict(_ state: SelectionState, toVisible order: [String]) -> SelectionState {
        let visible = Set(order)
        var next = state
        next.ids.formIntersection(visible)
        guard !next.ids.isEmpty else { return SelectionState() }
        if let primary = next.primary, !next.ids.contains(primary) { next.primary = order.first { next.ids.contains($0) } }
        if next.primary == nil { next.primary = order.first { next.ids.contains($0) } }
        if let anchor = next.anchor, !next.ids.contains(anchor) { next.anchor = next.primary }
        return next
    }

    /// Esc：清空。
    static func clear() -> SelectionState { SelectionState() }

    /// 刪除後：選刪除位置附近的下一張（優先原位置之後，沒有就往前）。
    static func afterRemoval(removed: Set<String>, previousOrder: [String], survivingOrder: [String]) -> SelectionState {
        guard let firstRemoved = previousOrder.firstIndex(where: { removed.contains($0) }) else {
            return SelectionState()
        }
        let after = previousOrder[firstRemoved...].first { !removed.contains($0) && survivingOrder.contains($0) }
        let before = previousOrder[..<firstRemoved].last { survivingOrder.contains($0) }
        guard let pick = after ?? before else { return SelectionState() }
        return SelectionState(ids: [pick], anchor: pick, primary: pick)
    }
}

// MARK: - 刪除計畫（純函式；實際搬移只在 TrashMover 一個地方）

struct DeletionPlan: Equatable {
    enum SkipReason: String, Equatable { case inUseAsWallpaper, bundledDemo, outsideDataRoot, symbolicLink }

    struct Item: Equatable {
        let id: String
        /// 要移到垃圾桶的檔案（主圖、sidecar、對應原圖；只列存在、在資料根目錄內、不是 symlink 的）。
        /// 都是已驗證過的實際位置（上層目錄已解開 symlink），搬移時直接用這些 URL。
        let files: [URL]
    }

    var items: [Item] = []
    var skipped: [(id: String, reason: SkipReason)] = []
    /// 主圖可刪、但附屬檔（sidecar／原圖）因 symlink 或越界被略過的，留下紀錄。
    var skippedFiles: [(url: URL, reason: SkipReason)] = []

    static func == (lhs: DeletionPlan, rhs: DeletionPlan) -> Bool {
        lhs.items == rhs.items && lhs.skipped.map(\.id) == rhs.skipped.map(\.id)
            && lhs.skipped.map(\.reason) == rhs.skipped.map(\.reason)
            && lhs.skippedFiles.map(\.url) == rhs.skippedFiles.map(\.url)
    }

    var fileCount: Int { items.reduce(0) { $0 + $1.files.count } }
}

enum FileKind: Equatable { case missing, regular, symbolicLink }

enum DeletionPlanner {
    /// 真實檔案系統：用 lstat，不跟隨 symlink。
    static func probe(_ url: URL) -> FileKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        return (info.st_mode & S_IFMT) == S_IFLNK ? .symbolicLink : .regular
    }

    /// - Parameters:
    ///   - targets: 要刪的圖（id 與檔案位置）
    ///   - dataRoot: 資料根目錄；不在它底下的檔案一律略過
    ///   - bundleRoot: App bundle（內建示範）位置
    ///   - inUse: 目前任一螢幕正在用的桌布檔
    ///   - probe: 檔案狀態（注入，測試不必真的建檔）
    static func plan(targets: [(id: String, url: URL)], dataRoot: URL, bundleRoot: URL?,
                     inUse: [URL], probe: (URL) -> FileKind = DeletionPlanner.probe) -> DeletionPlan {
        let root = canonical(dataRoot).path
        let bundle = bundleRoot.map { canonical($0).path }
        let inUsePaths = Set(inUse.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        var plan = DeletionPlan()
        for target in targets {
            let image = canonical(target.url)
            if let bundle, isInside(image.path, bundle) { plan.skipped.append((target.id, .bundledDemo)); continue }
            if !isInside(image.path, root) { plan.skipped.append((target.id, .outsideDataRoot)); continue }
            if probe(image) == .symbolicLink { plan.skipped.append((target.id, .symbolicLink)); continue }
            if inUsePaths.contains(image.path) { plan.skipped.append((target.id, .inUseAsWallpaper)); continue }
            var files = [image]
            /// 附屬檔：各自驗證在根目錄內、不是 symlink；有問題就略過那個檔並記錄。
            func attach(_ candidate: URL) -> Bool {
                let url = canonical(candidate)
                switch probe(url) {
                case .missing: return false
                case .symbolicLink: plan.skippedFiles.append((url, .symbolicLink)); return false
                case .regular:
                    guard isInside(url.path, root) else { plan.skippedFiles.append((url, .outsideDataRoot)); return false }
                    files.append(url); return true
                }
            }
            _ = attach(image.deletingPathExtension().appendingPathExtension("provenance.json"))
            if let original = originalURL(for: image, dataRoot: URL(fileURLWithPath: root, isDirectory: true)), attach(original) {
                _ = attach(canonical(original).deletingPathExtension().appendingPathExtension("provenance.json"))
            }
            plan.items.append(.init(id: target.id, files: files))
        }
        return plan
    }

    /// `wallpapers/<slug>-<id>-6k.jpg` → `originals/<slug>-<id>.png`。不是這個形狀就回 nil。
    static func originalURL(for wallpaper: URL, dataRoot: URL) -> URL? {
        let stem = wallpaper.deletingPathExtension().lastPathComponent
        let suffixes = ["-6k", "-5k"]
        guard let suffix = suffixes.first(where: { stem.lowercased().hasSuffix($0) }) else { return nil }
        let base = String(stem.dropLast(suffix.count))
        guard !base.isEmpty else { return nil }
        return dataRoot.appendingPathComponent("originals", isDirectory: true).appendingPathComponent(base + ".png")
    }

    /// 實際位置：上層目錄解開 symlink，最後一段保留原名（不跟隨 symlink 本身，才驗得出它是 symlink）。
    static func canonical(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}

/// 唯一會搬檔的地方：一律移到垃圾桶，不做永久刪除。
enum TrashMover {
    struct Outcome { var trashed: [URL: URL] = [:]; var failed: [URL] = [] }

    static func moveToTrash(_ files: [URL]) -> Outcome {
        var outcome = Outcome()
        for file in files {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
                outcome.trashed[file] = (resulting as URL?) ?? file
            } catch {
                outcome.failed.append(file)
            }
        }
        return outcome
    }
}
