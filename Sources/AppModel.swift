import Foundation
import AppKit
import Observation
import SwiftUI

/// App 的主狀態。全部在 MainActor 上，避免跨執行緒竄改。
@Observable
@MainActor
final class AppModel {
    // 瀏覽
    var wallpapers: [Wallpaper] = []
    /// 多選：集合＋錨點＋主要選取（主要選取給檢視器與設為桌布）。
    var selection = SelectionState()
    /// 相容舊介面：讀＝主要選取；寫＝單選那一張。
    var selectedID: String? {
        get { selection.primary }
        set { selection = newValue.map { SelectionState(ids: [$0], anchor: $0, primary: $0) } ?? SelectionState() }
    }
    let tagStore: TagStore
    /// 標籤變更計數，讓 SwiftUI 重繪（TagStore 本身不是 @Observable）。
    private(set) var tagRevision = 0
    var thumbnails: [String: NSImage] = [:]
    private(set) var favoriteIDs: Set<String> = []
    var rotationFavoritesOnly = false {
        didSet { preferences.set(rotationFavoritesOnly, forKey: "rotation.favoritesOnly") }
    }
    /// 每顆螢幕輪換不同張（只在「套用到所有螢幕」時有效）。
    var rotationPerDisplay = false {
        didSet { preferences.set(rotationPerDisplay, forKey: "rotation.perDisplay") }
    }
    /// 暫停：輪換與日夜切換都先停，設定保留。
    var isRotationPaused = false {
        didSet { preferences.set(isRotationPaused, forKey: "rotation.paused") }
    }
    var targetDisplayID: UInt32? {
        didSet {
            if let targetDisplayID { preferences.set(Int(targetDisplayID), forKey: "rotation.displayID") }
            else { preferences.removeObject(forKey: "rotation.displayID") }
        }
    }
    private(set) var isApplying = false

    // 狀態訊息
    var statusMessage = AppModel.readyMessage
    static var readyMessage: String { L("已就緒。啟動不會改動桌布。") }
    var errorMessage: String?

    // 生成
    var isGenerating = false
    var generationProgress = ""
    var generateCount = 1
    private(set) var lastGeneratedCount = 0
    var dynamicRevision = 0
    private var sceneWorkDirectory: URL?
    private var sceneWorkPrompt: String?

    // 輪換
    var rotationMode: RotationController.Mode = .off

    // 每日
    var dailyMode: DailyScheduler.Mode = .off

    private let desktop: any DesktopApplying
    let rotation: RotationController
    private let daily: DailyScheduler
    private let outputRoot: URL
    private let favoritesURL: URL
    private let preferences: UserDefaults
    private let isBackgroundWorker: Bool
    private let serviceFactory: @MainActor () throws -> GenerationService
    private let inUseWallpaperURLs: @MainActor () -> [URL]
    private let bundleRoot: URL?
    private let credentialAvailable: @MainActor () -> Bool
    private var generationTask: Task<Void, Never>?
    private var dailyTimer: Timer?
    private var generationLease: FileLease?
    /// 每次生成作業的代號。舊作業收尾時若代號不符，代表已經換了新作業，
    /// 舊作業不得再去動新作業的狀態。
    private var generationToken = 0

    /// 依賴都可以注入，測試才能用假 provider／假桌布跑，不碰真的 API 與桌面。
    ///
    /// 預設值寫成 nil、在 init 裡補，是因為預設引數是在非 actor 上下文求值的，
    /// 不能在那裡建立 @MainActor 的物件。
    init(desktop: (any DesktopApplying)? = nil,
         rotation: RotationController? = nil,
         daily: DailyScheduler? = nil,
         outputRoot: URL = LabPaths.deliveryRoot,
         serviceFactory: (@MainActor () throws -> GenerationService)? = nil,
         credentialAvailable: (@MainActor () -> Bool)? = nil,
         preferences: UserDefaults = .standard,
         isBackgroundWorker: Bool = false,
         inUseWallpaperURLs: (@MainActor () -> [URL])? = nil,
         bundleRoot: URL? = Bundle.main.bundleURL) {
        self.preferences = preferences
        self.tagStore = TagStore(root: outputRoot)
        self.inUseWallpaperURLs = inUseWallpaperURLs ?? { AppModel.currentDesktopURLs() }
        self.bundleRoot = bundleRoot
        self.isBackgroundWorker = isBackgroundWorker
        self.desktop = desktop ?? DesktopController()
        self.rotation = rotation ?? RotationController()
        self.daily = daily ?? DailyScheduler(defaults: preferences)
        self.outputRoot = outputRoot
        self.favoritesURL = outputRoot.appendingPathComponent("favorites.json")
        if let data = try? Data(contentsOf: favoritesURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.favoriteIDs = Set(ids)
        }
        self.serviceFactory = serviceFactory ?? { try AppModel.defaultServiceFactory() }
        self.credentialAvailable = credentialAvailable ?? { CredentialStore.load() != nil }
        self.dailyMode = self.daily.mode
        self.rotationMode = preferences.string(forKey: "rotation.mode").flatMap(RotationController.Mode.init(rawValue:)) ?? .off
        self.rotationFavoritesOnly = preferences.bool(forKey: "rotation.favoritesOnly")
        self.rotationPerDisplay = preferences.bool(forKey: "rotation.perDisplay")
        self.dailyRecipe = DailyRecipe.load(preferences)
        self.manualRecipe = DailyRecipe.load(preferences, prefix: DailyRecipe.manualPrefix)
        self.dynamicAutoFrequency = DynamicAutoFrequency.load(preferences)
        self.isRotationPaused = preferences.bool(forKey: "rotation.paused")
        self.targetDisplayID = (preferences.object(forKey: "rotation.displayID") as? NSNumber)?.uint32Value
        self.rotation.onTick = { [weak self] in self?.rotationTick() }
        reload()
        if tagStore.isReadOnly && !isBackgroundWorker { errorMessage = TagStore.TagError.readOnly.errorDescription }
        if !isBackgroundWorker { startDailyTimer() }
        refreshAutomationOwnership()
    }

    /// 正式環境的服務工廠：憑證只在記憶體裡取，取不到就丟錯。
    private static func defaultServiceFactory() throws -> GenerationService {
        guard let key = CredentialStore.load() else { throw GenerationError.missingCredential }
        return GenerationService(provider: OpenAIImageProvider(apiKey: key))
    }

    // MARK: - 瀏覽

    var selected: Wallpaper? {
        guard let selectedID else { return wallpapers.first }
        return wallpapers.first { $0.id == selectedID }
    }

    func reload() {
        wallpapers = WallpaperLibrary.load()
        thumbnails = [:]
        let present = Set(wallpapers.map(\.id))
        if selection.ids.isEmpty == false {
            var kept = selection
            kept.ids.formIntersection(present)
            if kept.ids.isEmpty { selectedID = wallpapers.first?.id; return }
            if let primary = kept.primary, !present.contains(primary) { kept.primary = wallpapers.first { kept.ids.contains($0.id) }?.id }
            if let anchor = kept.anchor, !present.contains(anchor) { kept.anchor = kept.primary }
            selection = kept
        } else if selectedID == nil {
            selectedID = wallpapers.first?.id
        }
    }

    // MARK: - 多選

    func click(_ wallpaper: Wallpaper, modifiers: SelectionModifiers, order: [String]) {
        selection = SelectionLogic.click(selection, id: wallpaper.id, modifiers: modifiers, order: order)
    }

    func selectAll(order: [String]) { selection = SelectionLogic.selectAll(selection, order: order) }
    func clearSelection() { selection = SelectionLogic.clear() }

    var selectedWallpapers: [Wallpaper] { wallpapers.filter { selection.ids.contains($0.id) } }

    // MARK: - 標籤

    var tags: [WallpaperTag] { _ = tagRevision; return tagStore.tags }

    func tags(for wallpaper: Wallpaper) -> [WallpaperTag] { _ = tagRevision; return tagStore.tags(for: wallpaper.id) }

    func tagCount(_ name: String) -> Int {
        _ = tagRevision
        return tagStore.count(for: name, among: Set(wallpapers.map(\.id)))
    }

    func ids(withTag name: String) -> Set<String> { _ = tagRevision; return tagStore.ids(with: name) }

    func allHaveTag(_ name: String, ids: Set<String>) -> Bool { _ = tagRevision; return tagStore.allHave(name, ids: ids) }

    /// 統一處理標籤操作的錯誤訊息。
    @discardableResult
    func editTags(_ body: (TagStore) throws -> Void) -> Bool {
        do {
            try body(tagStore)
            tagRevision += 1
            return true
        } catch {
            errorMessage = (error as? TagStore.TagError)?.errorDescription ?? L("標籤無法儲存，請確認桌布資料夾可以寫入。")
            return false
        }
    }

    /// 對所有選取的圖切換標籤：全部都有 → 移除；否則全部加上。
    func toggleTag(_ name: String, for ids: Set<String>) {
        let assign = !tagStore.allHave(name, ids: ids)
        editTags { try $0.set(name, assigned: assign, for: ids) }
    }

    // MARK: - 移到垃圾桶

    struct TrashSummary: Equatable {
        var trashed = 0
        var skippedInUse = 0
        var skippedOther = 0
        var failed = 0
        /// 移進垃圾桶後的位置（自測用來找回並清掉）。
        var trashedURLs: [URL] = []
    }

    /// 刪除計畫（純函式包一層：帶入目前桌面使用中的檔與 bundle 位置）。
    func deletionPlan(for ids: Set<String>) -> DeletionPlan {
        let targets = wallpapers.filter { ids.contains($0.id) }.map { (id: $0.id, url: $0.url) }
        return DeletionPlanner.plan(targets: targets, dataRoot: outputRoot, bundleRoot: bundleRoot,
                                    inUse: inUseWallpaperURLs())
    }

    /// 依計畫移到垃圾桶（實際搬移只在 TrashMover）；刪完清收藏與標籤、reload、選下一張。
    @discardableResult
    func trash(ids: Set<String>, order: [String]) -> TrashSummary {
        let plan = deletionPlan(for: ids)
        var summary = TrashSummary()
        summary.skippedInUse = plan.skipped.filter { $0.reason == .inUseAsWallpaper }.count
        summary.skippedOther = plan.skipped.count - summary.skippedInUse
        for file in plan.skippedFiles {
            LabLog.general.notice("trash: skipped attachment (\(file.reason.rawValue, privacy: .public))")
        }
        var removed = Set<String>()
        for item in plan.items {
            let outcome = TrashMover.moveToTrash(item.files)
            summary.trashedURLs.append(contentsOf: outcome.trashed.values)
            // 主圖移走才算刪除成功。
            if outcome.trashed[item.files[0]] != nil { removed.insert(item.id); summary.trashed += 1 }
            else { summary.failed += 1 }
        }
        if !removed.isEmpty {
            let favorites = favoriteIDs.subtracting(removed)
            if favorites != favoriteIDs { writeFavorites(favorites) }
            editTags { try $0.removeAssignments(for: removed) }
        }
        reload()
        selection = SelectionLogic.afterRemoval(removed: removed, previousOrder: order,
                                                survivingOrder: wallpapers.map(\.id).filter { order.contains($0) })
        if selection.ids.isEmpty, let first = wallpapers.first?.id { selectedID = first }
        var parts = [L("已移到垃圾桶 \(summary.trashed) 張")]
        if summary.skippedInUse > 0 { parts.append(L("略過 \(summary.skippedInUse) 張（正在當桌布）")) }
        if summary.skippedOther > 0 { parts.append(L("略過 \(summary.skippedOther) 張（內建示範、替身捷徑、不在資料夾內或檔案已不存在）")) }
        if summary.failed > 0 { parts.append(L("\(summary.failed) 張無法移動")) }
        statusMessage = parts.joined(separator: L("，")) + L("。")
        return summary
    }

    /// 目前所有螢幕正在用的桌布檔。
    static func currentDesktopURLs() -> [URL] {
        NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    func thumbnail(for wallpaper: Wallpaper) -> NSImage? {
        if let cached = thumbnails[wallpaper.id] { return cached }
        guard let cg = WallpaperLibrary.thumbnail(from: wallpaper.url) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails[wallpaper.id] = image
        return image
    }

    func previewImage(for wallpaper: Wallpaper) -> NSImage? {
        NSImage(contentsOf: wallpaper.url)
    }

    func select(_ wallpaper: Wallpaper) {
        selectedID = wallpaper.id
    }

    func toggleFavorite(_ wallpaper: Wallpaper) {
        var updated = favoriteIDs
        if !updated.insert(wallpaper.id).inserted { updated.remove(wallpaper.id) }
        writeFavorites(updated)
    }

    private func writeFavorites(_ updated: Set<String>) {
        do {
            if updated.isEmpty {
                if FileManager.default.fileExists(atPath: favoritesURL.path) {
                    try FileManager.default.removeItem(at: favoritesURL)
                }
            } else {
                try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
                try JSONEncoder().encode(updated.sorted()).write(to: favoritesURL, options: .atomic)
            }
            favoriteIDs = updated
        } catch {
            errorMessage = L("收藏無法儲存，請確認桌布資料夾可以寫入。")
        }
    }

    /// 上一張／下一張。`manual` 模式下會一併設為桌面。
    func advance(_ delta: Int) {
        Task { [weak self] in
            guard let self else { return }
            await self.step(delta, applyToDesktop: self.rotationMode == .manual)
        }
    }

    /// 定時輪換的一次跳動：換下一張並設為桌面。
    func rotationTick() {
        guard !preferences.bool(forKey: "dynamic.enabled"), !preferences.bool(forKey: "rotation.paused") else { return }
        Task { [weak self] in
            guard let self else { return }
            let pool = self.rotationFavoritesOnly ? self.wallpapers.filter { self.favoriteIDs.contains($0.id) } : self.wallpapers
            guard !pool.isEmpty else {
                if self.rotationFavoritesOnly {
                    self.stopRotation()
                    self.errorMessage = L("還沒有收藏的桌布，輪換已停止。")
                }
                return
            }
            await self.rotateDesktop(pool: pool)
        }
    }

    // MARK: - 選單列／快捷鍵／捷徑共用的桌面操作

    /// 背景輪換用的圖池：6K 成品（＋僅收藏）。
    func rotationPool() -> [Wallpaper] {
        wallpapers.filter {
            $0.pixelWidth >= Int(ImageResampler.sixK.width) && $0.pixelHeight >= Int(ImageResampler.sixK.height) &&
            (!rotationFavoritesOnly || favoriteIDs.contains($0.id))
        }
    }

    /// 立刻換下一張（選單列、快捷鍵、捷徑）。會把「上次輪換時間」設成現在，背景不會馬上又換掉。
    func skipToNext(at date: Date = Date()) async {
        guard !isDynamicActive else { statusMessage = L("日夜模式啟用中，桌布依時段切換。"); return }
        reload()
        let pool = rotationPool().isEmpty ? wallpapers : rotationPool()
        guard !pool.isEmpty else { errorMessage = L("沒有可套用的圖片。"); return }
        if await rotateDesktop(pool: pool) != .busy { preferences.set(date, forKey: "rotation.lastAttempt") }
    }

    /// 回到上一筆套用過的桌布（每顆螢幕不同張時，逐螢幕還原）。套用成功才改歷史與游標。
    func applyPrevious(at date: Date = Date()) async {
        guard !isDynamicActive else { statusMessage = L("日夜模式啟用中，桌布依時段切換。"); return }
        reload()
        let history = preferences.stringArray(forKey: "rotation.history") ?? []
        guard let target = RotationPlan.previous(in: history, existing: Set(wallpapers.map(\.id))) else {
            statusMessage = L("沒有上一張可以回去。"); return
        }
        guard !isApplying, let lease = try? FileLease.acquire(at: desktopLockURL) else {
            statusMessage = L("正在換桌布，請稍後再試。"); return
        }
        defer { withExtendedLifetime(lease) {} }
        let pairs = RotationPlan.decode(target.entry).compactMap { display, id in
            wallpapers.first { $0.id == id }.map { (display, $0) }
        }
        let connected = Set(desktop.displayIDs())
        let perDisplay = pairs.compactMap { display, wallpaper in display.flatMap { connected.contains($0) ? ($0, wallpaper) : nil } }
        // 實際套上去的圖（舊螢幕全部不在時，只把第一張套到目前螢幕）。
        let applied: [Wallpaper]
        if pairs.first?.0 != nil, !perDisplay.isEmpty {
            guard await applyPerDisplay(perDisplay, recordHistory: false) else { return }
            applied = perDisplay.map(\.1)
        } else if let wallpaper = pairs.first?.1 {
            guard await applyUnlocked(wallpaper, recordHistory: false) else { return }
            applied = [wallpaper]
        } else { return }
        preferences.set(target.remaining, forKey: "rotation.history")
        preferences.set(date, forKey: "rotation.lastAttempt")
        preferences.set(applied.last?.id, forKey: "rotation.lastID")
        selectedID = applied.first?.id
    }

    /// 收藏／取消收藏主螢幕目前的桌布。回傳是否找到那張。
    @discardableResult
    func toggleFavoriteForCurrentDesktop() -> Bool {
        reload()
        let current = Set(inUseWallpaperURLs().map { $0.standardizedFileURL.path })
        guard let wallpaper = wallpapers.first(where: { current.contains($0.url.standardizedFileURL.path) }) else {
            statusMessage = L("目前桌布不在圖庫裡。"); return false
        }
        toggleFavorite(wallpaper)
        statusMessage = favoriteIDs.contains(wallpaper.id) ? L("已收藏：\(wallpaper.name)") : L("已取消收藏：\(wallpaper.name)")
        return true
    }

    func setRotationPaused(_ paused: Bool) {
        isRotationPaused = paused
        preferences.synchronize()
        statusMessage = paused ? L("輪換已暫停。") : L("輪換已繼續。")
    }

    enum RotationOutcome { case busy, applied, failed }

    /// GUI、選單列與背景 worker 共用：同一時間只有一方在換桌布。
    private var desktopLockURL: URL { outputRoot.appendingPathComponent(".desktop-apply.lock") }

    /// 從游標往後挑；每顆螢幕不同張時一次挑「螢幕數」張，分別套用。套用成功才移動游標。
    @discardableResult
    private func rotateDesktop(pool: [Wallpaper]) async -> RotationOutcome {
        guard !isApplying, let lease = try? FileLease.acquire(at: desktopLockURL) else { return .busy }
        defer { withExtendedLifetime(lease) {} }
        let displays = rotationPerDisplay && targetDisplayID == nil ? desktop.displayIDs() : []
        let picks = RotationPlan.next(pool: pool.map(\.id), after: preferences.string(forKey: "rotation.lastID"),
                                      count: max(1, displays.count))
        guard let first = picks.first, let firstWallpaper = pool.first(where: { $0.id == first }) else { return .failed }
        let ok: Bool
        if displays.count > 1 {
            let assignments = zip(displays, picks).compactMap { display, id in
                pool.first { $0.id == id }.map { (display, $0) }
            }
            ok = await applyPerDisplay(assignments)
        } else {
            ok = await applyUnlocked(firstWallpaper)
        }
        guard ok else { return .failed }
        preferences.set(picks.last, forKey: "rotation.lastID")
        selectedID = first
        return .applied
    }

    /// 設定輪換模式。UI 的 Picker 一定要走這裡：
    /// 只改 `rotationMode` 不會讓 `rotation.mode` 變更，計時器也不會啟動。
    func setRotationMode(_ mode: RotationController.Mode) {
        if mode != .off { preferences.set(false, forKey: "dynamic.enabled") }
        rotationMode = mode
        preferences.set(mode.rawValue, forKey: "rotation.mode")
        refreshAutomationOwnership()
        statusMessage = mode == .off ? L("輪換已關閉。") : L("輪換模式：\(mode.title)")
    }

    /// 輪換計時器是否正在跑（`off` 與 `manual` 不需要計時器）。
    var isRotationRunning: Bool { rotation.isRunning }

    private var backgroundManaged: Bool { !isBackgroundWorker && BackgroundService.isEnabled(in: preferences) }

    func refreshAutomationOwnership() {
        rotation.mode = (isBackgroundWorker || backgroundManaged || preferences.bool(forKey: "dynamic.enabled")) ? .off : rotationMode
    }

    /// A worker resumes its own cursor and rotates only full-size 6K output.
    func performBackgroundRotation(at date: Date) async {
        if preferences.bool(forKey: "dynamic.enabled") {
            guard !preferences.bool(forKey: "rotation.paused") else { return }
            let phase = DynamicPhase.current(at: date, defaults: preferences)
            let directory = preferences.string(forKey: "dynamic.activeDirectory").map { URL(fileURLWithPath: $0) }
                ?? DynamicScene.directory
            let url = directory.appendingPathComponent(phase.rawValue + ".jpg")
            let key = url.path + ":" + String(targetDisplayID ?? 0)
            guard preferences.string(forKey: "dynamic.lastApplied") != key else { return }
            await apply(Wallpaper(id: "dynamic-\(phase.rawValue)", url: url,
                pixelWidth: 6144, pixelHeight: 3456, origin: .resampled), preserveDynamic: true)
            if errorMessage == nil {
                preferences.set(key, forKey: "dynamic.lastApplied")
                preferences.synchronize()
            }
            return
        }
        guard !preferences.bool(forKey: "rotation.paused") else { return }
        guard let interval = rotationMode.interval else { return }
        let previous = preferences.object(forKey: "rotation.lastAttempt") as? Date
        guard previous == nil || date.timeIntervalSince(previous!) >= interval else { return }
        reload()
        let pool = rotationPool()
        guard !pool.isEmpty else {
            statusMessage = L("等待可輪換的 6K 桌布。")
            return
        }
        // 失敗也記一次嘗試，避免每分鐘重試；被另一方佔用（busy）則下一分鐘再來。
        if await rotateDesktop(pool: pool) != .busy { preferences.set(date, forKey: "rotation.lastAttempt") }
    }

    private func step(_ delta: Int, applyToDesktop: Bool) async {
        let pool = applyToDesktop && rotationFavoritesOnly
            ? wallpapers.filter { favoriteIDs.contains($0.id) } : wallpapers
        guard !pool.isEmpty else {
            if applyToDesktop && rotationFavoritesOnly {
                stopRotation()
                errorMessage = L("還沒有收藏的桌布，輪換已停止。")
            }
            return
        }
        let currentIndex = pool.firstIndex { $0.id == selectedID }
        let nextIndex = currentIndex.map { ($0 + delta + pool.count) % pool.count }
            ?? (delta < 0 ? pool.count - 1 : 0)
        let next = pool[nextIndex]
        selectedID = next.id
        if applyToDesktop {
            await apply(next)
        }
    }

    // MARK: - 桌面

    /// 套用到所選螢幕；targetDisplayID 為 nil 時套用所有目前螢幕。
    ///
    /// 成功與否以「讀回相符」為準：
    /// - 沒有任何螢幕 → 失敗（不能顯示成功）。
    /// - 設定成功但讀回不符 → 算失敗（不能顯示成功卻讀回 0 顆）。
    /// 對外的套用：先拿跨行程的換桌布鎖，跟背景 worker、選單列互斥。
    @discardableResult
    func apply(_ wallpaper: Wallpaper, preserveDynamic: Bool = false, recordHistory: Bool = true) async -> Bool {
        guard !isApplying, let lease = try? FileLease.acquire(at: desktopLockURL) else {
            statusMessage = L("正在換桌布，請稍後再試。"); return false
        }
        defer { withExtendedLifetime(lease) {} }
        return await applyUnlocked(wallpaper, preserveDynamic: preserveDynamic, recordHistory: recordHistory)
    }

    /// 呼叫端已持有換桌布鎖。
    private func applyUnlocked(_ wallpaper: Wallpaper, preserveDynamic: Bool = false, recordHistory: Bool = true) async -> Bool {
        guard !isApplying else { return false }
        isApplying = true
        defer { isApplying = false }
        if !preserveDynamic {
            preferences.set(false, forKey: "dynamic.enabled")
            dynamicRevision += 1
        }
        let target = targetDisplayID
        let results = await desktop.setWallpaper(wallpaper.url, onDisplayID: target)
        guard !results.isEmpty else {
            errorMessage = target == nil ? L("找不到任何螢幕，桌布沒有套用。") : L("所選螢幕已中斷連線，桌布沒有套用。")
            statusMessage = L("未套用桌布：沒有螢幕。")
            return false
        }
        let matched = results.filter { $0.applied && $0.readbackMatched }.count
        let failed = results.filter { !$0.applied }.count
        let unreadable = results.filter { $0.applied && !$0.readbackMatched }.count

        if failed == 0 && unreadable == 0 {
            statusMessage = L("已設為目前桌布：\(wallpaper.name)（\(results.count) 顆螢幕，讀回相符 \(matched) 顆）。")
            errorMessage = nil
            if recordHistory && !preserveDynamic { pushHistory(RotationPlan.entry(wallpaper.id)) }
            return true
        } else {
            var parts: [String] = []
            if failed > 0 { parts.append(L("\(failed) 顆設定失敗")) }
            if unreadable > 0 { parts.append(L("\(unreadable) 顆尚未讀回新路徑")) }
            let joined = parts.joined(separator: L("、"))
            errorMessage = L("桌布套用尚未完全確認：\(joined)。")
            statusMessage = L("已嘗試設為目前桌布：\(wallpaper.name)（\(results.count) 顆螢幕，讀回相符 \(matched) 顆）。")
        }
        return false
    }

    /// 每顆螢幕各套一張。成功與否一樣以讀回為準。
    @discardableResult
    private func applyPerDisplay(_ assignments: [(UInt32, Wallpaper)], recordHistory: Bool = true) async -> Bool {
        guard !isApplying, !assignments.isEmpty else { return false }
        isApplying = true
        defer { isApplying = false }
        preferences.set(false, forKey: "dynamic.enabled")
        dynamicRevision += 1
        var results: [ScreenApplyResult] = []
        for (display, wallpaper) in assignments {
            results += await desktop.setWallpaper(wallpaper.url, onDisplayID: display)
        }
        let ok = results.filter { $0.applied && $0.readbackMatched }.count
        if !results.isEmpty && ok == results.count {
            statusMessage = L("已在 \(assignments.count) 顆螢幕各換一張（讀回相符 \(ok) 顆）。")
            errorMessage = nil
            if recordHistory { pushHistory(RotationPlan.entry(perDisplay: assignments.map { ($0.0, $0.1.id) })) }
            return true
        } else if results.isEmpty {
            errorMessage = L("找不到任何螢幕，桌布沒有套用。")
        } else {
            errorMessage = L("桌布套用尚未完全確認：讀回相符 \(ok)／\(results.count) 顆。")
        }
        return false
    }

    private func pushHistory(_ entry: String) {
        var history = preferences.stringArray(forKey: "rotation.history") ?? []
        if history.last != entry { history.append(entry) }
        preferences.set(Array(history.suffix(RotationPlan.historyLimit)), forKey: "rotation.history")
    }

    func applySelected() async {
        guard let wallpaper = selected else {
            errorMessage = L("沒有可套用的圖片。")
            return
        }
        await apply(wallpaper)
    }

    func stopRotation() {
        // 走 setRotationMode，確保 rotationMode 與 rotation.mode 不會各寫各的。
        setRotationMode(.off)
        statusMessage = L("已停止輪換。")
    }

    /// `directory` 是場景庫挑的場景；nil＝目前場景（舊行為）。流程不變，只改用哪個場景目錄。
    func activateDynamic(directory: URL? = nil) async {
        let sceneDirectory = directory ?? DynamicScene.directory
        guard DynamicSceneEntry.isComplete(sceneDirectory) else { errorMessage = L("四個時段尚未備齊。"); return }
        do {
            if !BackgroundService.isEnabled(in: preferences) {
                guard let executable = Bundle.main.executableURL else { return }
                try BackgroundService.enable(executableURL: executable, defaults: preferences)
            }
            setRotationMode(.off)
            preferences.set(true, forKey: "dynamic.enabled")
            preferences.set(sceneDirectory.path, forKey: "dynamic.activeDirectory")
            preferences.removeObject(forKey: "dynamic.lastApplied")
            preferences.synchronize()
            dynamicRevision += 1
            refreshAutomationOwnership()
            await performBackgroundRotation(at: Date())
        } catch { errorMessage = error.localizedDescription }
    }

    var isDynamicActive: Bool { preferences.bool(forKey: "dynamic.enabled") }

    /// 每日 10 張用哪些風格、自己的想法。新的一批才生效，進行中的批次照原計畫。
    var dailyRecipe = DailyRecipe() { didSet { dailyRecipe.save(preferences) } }
    /// 手動「產生桌布」的分類與自己的 Prompt（與每日排程分開記）。
    var manualRecipe = DailyRecipe() { didSet { manualRecipe.save(preferences, prefix: DailyRecipe.manualPrefix) } }
    /// 日夜 AI 自動：每天／每週自動挑場景生成。
    var dynamicAutoFrequency = DynamicAutoFrequency.off { didSet { dynamicAutoFrequency.save(preferences) } }

    /// 背景正在用的場景目錄（日夜模式啟用時）。
    var activeDynamicDirectory: URL? {
        guard isDynamicActive else { return nil }
        return preferences.string(forKey: "dynamic.activeDirectory").map { URL(fileURLWithPath: $0) } ?? DynamicScene.directory
    }

    /// 四時段生成進度：已完成幾步（順序 白天 → 清晨 → 黃昏 → 夜晚）。
    private(set) var dynamicStepsDone = 0

    /// 日夜生成用的圖片來源；自測換成假的，不打真 API。
    var sceneProviderFactory: @MainActor () throws -> any SceneImageProvider = {
        guard let key = CredentialStore.load() else { throw GenerationError.missingCredential }
        return OpenAIImageProvider(apiKey: key)
    }

    func startDynamicGeneration(prompt: String) {
        guard !isGenerating else { return }
        do {
            let prompt = try OpenAIImageProvider.validatePrompt(prompt)
            if sceneWorkPrompt != prompt {
                sceneWorkDirectory = outputRoot.appendingPathComponent("dynamic/scenes/\(UUID().uuidString)")
                sceneWorkPrompt = prompt
            }
            runSceneGeneration(prompt: prompt, directory: sceneWorkDirectory!, onSuccess: { _ in
                self.statusMessage = L("四時段 6K 已生成。可預覽，再設定為日夜桌布。")
                self.sceneWorkDirectory = nil
                self.sceneWorkPrompt = nil
            }, onFailure: { error in
                if error is CancellationError { self.statusMessage = L("已取消；已下載的時段保留，可用相同描述續作。") }
                else {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = L("日夜生成未完成；相同描述重試會保留已完成時段。")
                }
            })
        } catch { errorMessage = error.localizedDescription }
    }

    /// 四時段生成共用流程：拿生成鎖 → 生成 → 發布。回傳是否真的開始。
    @discardableResult
    private func runSceneGeneration(prompt: String, directory: URL, quietWhenBusy: Bool = false,
                                    beforeStart: (() throws -> Void)? = nil,
                                    onSuccess: @escaping @MainActor (GeneratedScene) async -> Void,
                                    onFailure: @escaping @MainActor (Error) -> Void) -> Bool {
        guard !isGenerating else { return false }
        do {
            guard let lease = try FileLease.acquire(at: outputRoot.appendingPathComponent(".generation.lock")) else {
                // 自動檢查遇到別人在生成：下一分鐘再看，不算錯誤。
                if !quietWhenBusy { errorMessage = L("背景或另一個視窗正在生成，請稍後再試。") }
                return false
            }
            let provider = try sceneProviderFactory()
            // 付費請求送出前的最後一步（自動場景在這裡記次數）。
            try beforeStart?()
            generationLease = lease
            isGenerating = true
            errorMessage = nil
            generationProgress = L("準備四時段場景…")
            dynamicStepsDone = 0
            generationTask = Task {
                defer { isGenerating = false; generationLease = nil; generationProgress = "" }
                do {
                    let scene = try await DynamicGenerator(provider: provider)
                        .generate(prompt: prompt, directory: directory) { count in
                            Task { @MainActor in
                                self.generationProgress = L("已完成 \(count)／4 個時段")
                                self.dynamicStepsDone = count
                            }
                        }
                    try scene.publish()
                    dynamicRevision += 1
                    await onSuccess(scene)
                } catch { onFailure(error) }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - 日夜 AI 自動

    private var dynamicAutoURL: URL { outputRoot.appendingPathComponent("dynamic/auto.json") }
    var dynamicAutoState: DynamicAutoState? { DynamicAutoState.load(from: dynamicAutoURL) }

    private var plannerContext: (southern: Bool, chinese: Bool) {
        let southern = DynamicTiming.load(preferences) == .solar && Coordinate.load(preferences).0.latitude < 0
        let chinese = (Locale.preferredLanguages.first ?? "").hasPrefix("zh")
        return (southern, chinese)
    }

    /// 排程檢查（背景每分鐘）：這一期還沒做就挑場景生成。缺 key 不記次數。
    func checkDynamicAuto(now: Date = Date()) {
        guard !backgroundManaged, !isGenerating, dynamicAutoFrequency != .off else { return }
        let context = plannerContext
        guard let state = DynamicAutoPlanner.due(state: dynamicAutoState, now: now, frequency: dynamicAutoFrequency,
                                                 southern: context.southern, chinese: context.chinese) else { return }
        guard credentialAvailable() else { return }
        startAutoScene(state, automatic: true)
    }

    /// 「現在用 AI 生成一組」。
    func generateAutoSceneNow(now: Date = Date()) {
        guard !isGenerating else { return }
        let context = plannerContext
        startAutoScene(DynamicAutoPlanner.manual(state: dynamicAutoState, now: now, frequency: dynamicAutoFrequency,
                                                 southern: context.southern, chinese: context.chinese))
    }

    private func startAutoScene(_ state: DynamicAutoState, automatic: Bool = false) {
        var state = state
        let url = dynamicAutoURL
        let directory = outputRoot.appendingPathComponent("dynamic/scenes/\(state.sceneID)")
        runSceneGeneration(prompt: state.prompt, directory: directory, quietWhenBusy: automatic, beforeStart: {
            state.attempts += 1
            state.retryAfter = nil
            try state.save(to: url)
        }, onSuccess: { _ in
            state.recordSuccess()
            try? state.save(to: url)
            self.statusMessage = L("AI 已生成新的日夜場景：\(state.prompt)")
            // 日夜模式開著就直接換成新場景；沒開只放進場景庫。
            if self.isDynamicActive {
                self.preferences.set(directory.path, forKey: "dynamic.activeDirectory")
                self.preferences.removeObject(forKey: "dynamic.lastApplied")
                await self.performBackgroundRotation(at: Date())
            }
        }, onFailure: { error in
            state.recordFailure(retryable: DynamicAutoState.isRetryable(error), now: Date())
            try? state.save(to: url)
            if !DynamicAutoState.isCancellation(error) {
                self.errorMessage = error.localizedDescription
                self.statusMessage = L("AI 日夜場景未完成；已完成的時段保留，稍後自動續作。")
            }
        })
    }

    // MARK: - 生成

    /// 手動生成（與每日排程共用同一條路徑）。
    @discardableResult
    func startGeneration(count: Int, dailyAttempt: Bool = false) -> Bool {
        guard !isGenerating else {
            errorMessage = L("已經有一個生成作業在進行中。")
            return false
        }
        let lease: FileLease
        do {
            guard let acquired = try FileLease.acquire(at: outputRoot.appendingPathComponent(".generation.lock")) else {
                if !dailyAttempt { errorMessage = L("另一個視窗或背景作業正在生成，請稍後再試。") }
                return false
            }
            lease = acquired
        } catch {
            errorMessage = L("無法取得生成工作鎖，請確認資料夾可以寫入。")
            return false
        }
        let recipe = dailyAttempt ? dailyRecipe : manualRecipe
        var service: GenerationService
        if let made = try? serviceFactory() {
            service = made
        } else if recipe.isLocalOnly {
            // 只選純色／漸層：本機畫，不需要 API key。
            service = GenerationService(provider: LocalOnlyProvider())
        } else {
            errorMessage = GenerationError.missingCredential.localizedDescription
            return false
        }
        service.recipe = recipe
        let batchDay = dailyAttempt ? DailyScheduler.dayKey(Date()) : nil
        if let day = batchDay {
            guard !daily.alreadyAttempted() || DailyBatch.canResume(root: outputRoot, day: day) else { return false }
            do { _ = try DailyBatch.prepare(root: outputRoot, day: day, count: count,
                                            plan: DailyPlan.make(day: day, count: count, recipe: dailyRecipe)) }
            catch { errorMessage = L("每日進度無法讀取或儲存，已停止以避免重複生成。"); return false }
            daily.markAttempt()
        }
        generationLease = lease
        lastGeneratedCount = 0
        isGenerating = true
        errorMessage = nil
        generationProgress = L("準備中…")
        statusMessage = L("開始生成 \(count) 張桌布。")
        generationToken += 1
        let token = generationToken

        generationTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == self.generationToken { self.generationLease = nil } }
            let progress: @Sendable (Int, Int) -> Void = { done, total in
                Task { @MainActor in
                    guard token == self.generationToken else { return }
                    self.generationProgress = L("已產生 \(done)／\(total) 張")
                    self.lastGeneratedCount = done
                }
            }
            do {
                let results = try await service.generate(count: count,
                                                         outputRoot: outputRoot,
                                                         batchDay: batchDay,
                                                         progress: progress)
                guard token == self.generationToken else { return }
                isGenerating = false
                generationProgress = ""
                reload()
                lastGeneratedCount = results.count
                statusMessage = L("已生成 \(results.count) 張（原生 PNG 與 6K 重採樣都保留）。")
            } catch is CancellationError {
                guard token == self.generationToken else { return }
                isGenerating = false
                generationProgress = ""
                statusMessage = L("已取消生成。")
            } catch let error as GenerationError where error == .cancelled {
                guard token == self.generationToken else { return }
                isGenerating = false
                generationProgress = ""
                statusMessage = L("已取消生成。")
            } catch {
                guard token == self.generationToken else { return }
                isGenerating = false
                generationProgress = ""
                let generationError = error as? GenerationError
                errorMessage = generationError?.localizedDescription ?? error.localizedDescription
                if let day = batchDay,
                   let batch = try? DailyBatch.load(root: outputRoot, day: day) {
                    lastGeneratedCount = batch.completed.count
                    if batch.retryAfter != nil && batch.attempts[batch.completed.count] < 3 {
                        errorMessage = L("連線或服務暫時失敗；已保留 \(batch.completed.count)／\(count) 張，稍後補試。每個主題最多補試 2 次。")
                    }
                }
                statusMessage = L("生成失敗。")
                reload()
            }
        }
        return true
    }

    /// 取消生成。
    ///
    /// 這裡**不**直接清掉 `isGenerating`：舊 Task 還在收尾，
    /// 先清掉會讓使用者馬上開第二批，而舊 Task 的收尾又會把新作業的狀態清掉。
    /// busy 狀態留到 Task 真的 unwind，由 Task 自己收尾。
    func cancelGeneration() {
        guard isGenerating else { return }
        generationTask?.cancel()
        generationProgress = L("正在取消…")
        statusMessage = L("正在取消生成…")
    }

    // MARK: - 每日排程

    func setDailyMode(_ mode: DailyScheduler.Mode) {
        dailyMode = mode
        daily.mode = mode
        statusMessage = mode == .off ? L("每日生成已關閉。") : L("已記住每日生成設定：每天最多一批 \(mode.count) 張。")
    }

    private func startDailyTimer() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDaily(); self?.checkDynamicAuto() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }

    /// 每分鐘檢查一次：到了新的一天且設定開啟，就跑一批。
    func checkDaily() {
        guard !backgroundManaged else { return }
        guard dailyMode != .off else { return }
        guard !isGenerating else { return }          // 不允許同時生成
        guard !daily.alreadyAttempted() || DailyBatch.canResume(root: outputRoot, day: DailyScheduler.dayKey(Date())) else { return }
        // 憑證要先驗證：缺 key 時**不能**記當日 attempt，
        // 否則使用者補好 key 當天就不會再跑了。
        guard credentialAvailable() || dailyRecipe.isLocalOnly else {
            let message = GenerationError.missingCredential.localizedDescription
            if errorMessage != message { errorMessage = message }
            statusMessage = L("每日自動產生：找不到 API 憑證，未執行（補上憑證後當天仍會執行）。")
            return
        }
        statusMessage = L("每日自動產生：開始產生 \(dailyMode.count) 張。")
        startGeneration(count: dailyMode.count, dailyAttempt: true)
    }

    // MARK: - 其他

    func openWallpaperFolder() {
        do {
            try FileManager.default.createDirectory(at: LabPaths.wallpapersDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(LabPaths.wallpapersDir)
        } catch { errorMessage = L("無法開啟圖片資料夾，請確認儲存位置可以寫入。") }
    }
}

/// 只畫純色／漸層時用：不會真的被呼叫（本機規格在送出前就畫好了），萬一被叫到就回報缺 key。
struct LocalOnlyProvider: ImageProvider {
    func generateImage(prompt: String) async throws -> Data { throw GenerationError.missingCredential }
}
