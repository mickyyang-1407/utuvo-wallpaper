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
    var selectedID: String?
    var thumbnails: [String: NSImage] = [:]
    private(set) var favoriteIDs: Set<String> = []
    var rotationFavoritesOnly = false {
        didSet { preferences.set(rotationFavoritesOnly, forKey: "rotation.favoritesOnly") }
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
         isBackgroundWorker: Bool = false) {
        self.preferences = preferences
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
        self.targetDisplayID = (preferences.object(forKey: "rotation.displayID") as? NSNumber)?.uint32Value
        self.rotation.onTick = { [weak self] in self?.rotationTick() }
        reload()
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
        if let selectedID, !wallpapers.contains(where: { $0.id == selectedID }) {
            self.selectedID = wallpapers.first?.id
        } else if selectedID == nil {
            selectedID = wallpapers.first?.id
        }
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
        guard !preferences.bool(forKey: "dynamic.enabled") else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.step(1, applyToDesktop: true)
        }
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
            let phase = DynamicPhase.current(at: date)
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
        guard let interval = rotationMode.interval else { return }
        let previous = preferences.object(forKey: "rotation.lastAttempt") as? Date
        guard previous == nil || date.timeIntervalSince(previous!) >= interval else { return }
        reload()
        let pool = wallpapers.filter {
            $0.pixelWidth >= Int(ImageResampler.sixK.width) && $0.pixelHeight >= Int(ImageResampler.sixK.height) &&
            (!rotationFavoritesOnly || favoriteIDs.contains($0.id))
        }
        guard !pool.isEmpty else {
            statusMessage = L("等待可輪換的 6K 桌布。")
            return
        }
        let cursor = preferences.string(forKey: "rotation.lastID")
        let nextIndex = pool.firstIndex(where: { $0.id == cursor }).map { ($0 + 1) % pool.count } ?? 0
        let next = pool[nextIndex]
        preferences.set(date, forKey: "rotation.lastAttempt")
        preferences.set(next.id, forKey: "rotation.lastID")
        selectedID = next.id
        await apply(next)
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
    func apply(_ wallpaper: Wallpaper, preserveDynamic: Bool = false) async {
        guard !isApplying else { return }
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
            return
        }
        let matched = results.filter { $0.applied && $0.readbackMatched }.count
        let failed = results.filter { !$0.applied }.count
        let unreadable = results.filter { $0.applied && !$0.readbackMatched }.count

        if failed == 0 && unreadable == 0 {
            statusMessage = L("已設為目前桌布：\(wallpaper.name)（\(results.count) 顆螢幕，讀回相符 \(matched) 顆）。")
            errorMessage = nil
        } else {
            var parts: [String] = []
            if failed > 0 { parts.append(L("\(failed) 顆設定失敗")) }
            if unreadable > 0 { parts.append(L("\(unreadable) 顆尚未讀回新路徑")) }
            let joined = parts.joined(separator: L("、"))
            errorMessage = L("桌布套用尚未完全確認：\(joined)。")
            statusMessage = L("已嘗試設為目前桌布：\(wallpaper.name)（\(results.count) 顆螢幕，讀回相符 \(matched) 顆）。")
        }
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

    func activateDynamic() async {
        guard DynamicScene.isReady else { errorMessage = L("四個時段尚未備齊。"); return }
        do {
            if !BackgroundService.isEnabled(in: preferences) {
                guard let executable = Bundle.main.executableURL else { return }
                try BackgroundService.enable(executableURL: executable, defaults: preferences)
            }
            setRotationMode(.off)
            preferences.set(true, forKey: "dynamic.enabled")
            preferences.set(DynamicScene.directory.path, forKey: "dynamic.activeDirectory")
            preferences.removeObject(forKey: "dynamic.lastApplied")
            preferences.synchronize()
            dynamicRevision += 1
            refreshAutomationOwnership()
            await performBackgroundRotation(at: Date())
        } catch { errorMessage = error.localizedDescription }
    }

    var isDynamicActive: Bool { preferences.bool(forKey: "dynamic.enabled") }

    func startDynamicGeneration(prompt: String) {
        guard !isGenerating else { return }
        do {
            let prompt = try OpenAIImageProvider.validatePrompt(prompt)
            guard let lease = try FileLease.acquire(at: outputRoot.appendingPathComponent(".generation.lock")) else {
                errorMessage = L("背景或另一個視窗正在生成，請稍後再試。"); return
            }
            guard let key = CredentialStore.load() else { throw GenerationError.missingCredential }
            if sceneWorkPrompt != prompt {
                sceneWorkDirectory = outputRoot.appendingPathComponent("dynamic/scenes/\(UUID().uuidString)")
                sceneWorkPrompt = prompt
            }
            let directory = sceneWorkDirectory!
            generationLease = lease
            isGenerating = true
            errorMessage = nil
            generationProgress = L("準備四時段場景…")
            generationTask = Task {
                defer { isGenerating = false; generationLease = nil; generationProgress = "" }
                do {
                    let scene = try await DynamicGenerator(provider: OpenAIImageProvider(apiKey: key))
                        .generate(prompt: prompt, directory: directory) { count in
                            Task { @MainActor in self.generationProgress = L("已完成 \(count)／4 個時段") }
                        }
                    try scene.publish()
                    dynamicRevision += 1
                    statusMessage = L("四時段 6K 已生成。可預覽，再設定為日夜桌布。")
                    sceneWorkDirectory = nil
                    sceneWorkPrompt = nil
                } catch is CancellationError { statusMessage = L("已取消；已下載的時段保留，可用相同描述續作。") }
                catch {
                    errorMessage = error.localizedDescription
                    statusMessage = L("日夜生成未完成；相同描述重試會保留已完成時段。")
                }
            }
        } catch { errorMessage = error.localizedDescription }
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
        guard let service = try? serviceFactory() else {
            errorMessage = GenerationError.missingCredential.localizedDescription
            return false
        }
        let batchDay = dailyAttempt ? DailyScheduler.dayKey(Date()) : nil
        if let day = batchDay {
            guard !daily.alreadyAttempted() || DailyBatch.canResume(root: outputRoot, day: day) else { return false }
            do { _ = try DailyBatch.prepare(root: outputRoot, day: day, count: count) }
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
            MainActor.assumeIsolated { self?.checkDaily() }
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
        guard credentialAvailable() else {
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
