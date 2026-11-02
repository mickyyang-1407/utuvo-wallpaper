import BackgroundTasks
import Foundation
import Photos
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [WallpaperItem] = [] { didSet { titles = WallpaperTitles.titles(for: items) } }
    @Published private(set) var titles: [String: String] = [:]
    @Published var liveStatus: (ok: Bool, text: String)?
    @Published var favorites: Set<String> = []
    @Published var pinnedID: String?
    @Published var favoritesOnly = false { didSet { prefs.favoritesOnly = favoritesOnly } }
    @Published var dailyEnabled = false { didSet { prefs.dailyEnabled = dailyEnabled; if dailyEnabled { BackgroundScheduler.schedule() } } }
    @Published var dynamicEnabled = false { didSet { prefs.dynamicEnabled = dynamicEnabled } }
    @Published var dynamicSceneID = "demo"
    @Published var publishedScene: SceneRecord?
    /// 每日 10 張的風格與自己的想法；新的一批才生效。
    @Published var dailyRecipe = DailyRecipe() { didSet { dailyRecipe.save(prefs.defaults) } }
    /// 日夜 AI 自動：每天／每週自動挑場景生成。
    @Published var dynamicAutoFrequency = DynamicAutoFrequency.off { didSet { dynamicAutoFrequency.save(prefs.defaults) } }
    @Published private(set) var dynamicAutoState: DynamicAutoState?

    @Published var dailyProgress: (done: Int, total: Int)?
    @Published var isDailyRunning = false
    @Published var dailyError: String?

    @Published var sceneProgress: Int?
    @Published var sceneError: String?

    @Published var keyStored = false
    @Published var keyFromEnvironment = false
    @Published var usedBytes = 0
    @Published var message: String?

    let paths = AppPaths.shared
    let prefs = Preferences()
    let store = KeychainCredentialStore()

    init() {
        paths.prepare()
        favorites = prefs.favorites
        pinnedID = prefs.pinnedID
        favoritesOnly = prefs.favoritesOnly
        dailyEnabled = prefs.dailyEnabled
        dynamicEnabled = prefs.dynamicEnabled
        dynamicSceneID = prefs.dynamicSceneID
        dailyRecipe = DailyRecipe.load(prefs.defaults)
        dynamicAutoFrequency = DynamicAutoFrequency.load(prefs.defaults)
        reload()
    }

    func title(for item: WallpaperItem) -> String {
        titles[item.id] ?? WallpaperTitles.baseTitle(item, formatter: WallpaperTitles.dayFormatter())
    }

    func reload() {
        items = WallpaperLibrary.load(paths: paths)
        publishedScene = SceneGenerationService.published(paths: paths)
        dynamicAutoState = DynamicAutoState.load(from: paths.dynamicAutoState)
        if dynamicSceneID != "demo", publishedScene?.id != dynamicSceneID { dynamicSceneID = "demo"; prefs.dynamicSceneID = "demo" }
        dailyProgress = DailyGenerationService.status(paths: paths, day: AppPaths.dayString(Date()))
        keyStored = (try? store.exists()) == true
        keyFromEnvironment = !keyStored && ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty == false
        usedBytes = paths.usedBytes()
    }

    func provider() throws -> ImageProvider {
        try ProviderFactory.make(store: store)
    }

    #if DEBUG
    private var liveOneStarted = false

    /// `-UTUVOLiveOne YES` 才會啟動；回傳是否啟動。只用真的 OpenAI provider 跑 1 張。
    @discardableResult
    func startLiveOneIfRequested(defaults: UserDefaults = .standard) -> Bool {
        guard LiveOneCheck.isRequested(defaults), !liveOneStarted else { return false }
        liveOneStarted = true
        liveStatus = (true, L("實測生成中（1 張）…"))
        Task {
            do {
                guard let credential = CredentialResolver.resolve(store: store) else { throw GenerationError.missingCredential }
                let service = DailyGenerationService(provider: OpenAIImageProvider(apiKey: credential.key),
                                                     paths: paths, target: DeviceScreen.nativePixels)
                let results = try await GenerationLease.shared.run { try await service.run(day: LiveOneCheck.day(), count: 1) }
                liveStatus = (true, L("實測完成：\(results.count) 張已加入圖庫。"))
            } catch {
                liveStatus = (false, L("實測失敗：\((error as? LocalizedError)?.errorDescription ?? L("生成失敗。"))"))
            }
            reload()
        }
        return true
    }
    #endif

    // MARK: 收藏／釘選

    func toggleFavorite(_ item: WallpaperItem) {
        if favorites.contains(item.id) { favorites.remove(item.id) } else { favorites.insert(item.id) }
        prefs.favorites = favorites
    }

    func togglePin(_ item: WallpaperItem) {
        pinnedID = pinnedID == item.id ? nil : item.id
        prefs.pinnedID = pinnedID
    }

    func delete(_ item: WallpaperItem) {
        WallpaperLibrary.delete(item, paths: paths)
        favorites.remove(item.id); prefs.favorites = favorites
        if pinnedID == item.id { pinnedID = nil; prefs.pinnedID = nil }
        reload()
    }

    func deviceFile(for item: WallpaperItem) -> URL? {
        try? WallpaperLibrary.deviceJPEG(for: item, paths: paths, target: DeviceScreen.nativePixels)
    }

    func saveToPhotos(_ item: WallpaperItem) async {
        guard let url = deviceFile(for: item) else { message = L("找不到這張桌布的檔案。"); return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = L("沒有加入照片的權限。請到「設定」App 允許 UTUVO Wallpaper 加入照片。")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }
            message = L("已儲存到照片。")
        } catch {
            message = L("儲存到照片失敗。")
        }
    }

    // MARK: 每日批次

    func runDailyIfNeeded() {
        guard dailyEnabled, !isDailyRunning else { return }
        let day = AppPaths.dayString(Date())
        guard DailyGenerationService.hasWork(paths: paths, day: day) else { return }
        Task { await runDaily() }
    }

    func runDaily() async {
        guard !isDailyRunning else { return }
        isDailyRunning = true
        dailyError = nil
        defer { isDailyRunning = false; reload() }
        do {
            // 只選純色／漸層：本機畫，不需要 API key。
            let source: ImageProvider = dailyRecipe.isLocalOnly ? ((try? provider()) ?? LocalOnlyProvider()) : try provider()
            let service = DailyGenerationService(provider: source, paths: paths, target: DeviceScreen.nativePixels,
                                                 recipe: dailyRecipe)
            _ = try await GenerationLease.shared.run {
                try await service.run(day: AppPaths.dayString(Date())) { done, total in
                    Task { @MainActor in self.dailyProgress = (done, total); self.items = WallpaperLibrary.load(paths: self.paths) }
                }
            }
        } catch {
            dailyError = (error as? LocalizedError)?.errorDescription ?? L("生成失敗。")
        }
    }

    // MARK: 日夜場景

    func generateScene(_ prompt: String) async {
        guard sceneProgress == nil else { return }
        sceneError = nil
        sceneProgress = 0
        defer { sceneProgress = nil; reload() }
        do {
            let service = SceneGenerationService(provider: try provider(), paths: paths, target: DeviceScreen.nativePixels)
            let record = try await GenerationLease.shared.run {
                try await service.generate(prompt: prompt) { step in Task { @MainActor in self.sceneProgress = step } }
            }
            dynamicSceneID = record.id
            prefs.dynamicSceneID = record.id
        } catch {
            sceneError = (error as? LocalizedError)?.errorDescription ?? L("生成失敗。")
        }
    }

    // MARK: 日夜 AI 自動

    /// App 打開時檢查：這一期還沒做就讓 AI 挑場景生成。缺 key 不記次數。
    func runDynamicAutoIfNeeded(now: Date = Date()) {
        guard sceneProgress == nil, dynamicAutoFrequency != .off, keyStored || keyFromEnvironment else { return }
        let context = Self.plannerContext(prefs.defaults)
        guard let state = DynamicAutoPlanner.due(state: DynamicAutoState.load(from: paths.dynamicAutoState), now: now,
                                                 frequency: dynamicAutoFrequency, southern: context.southern,
                                                 chinese: context.chinese) else { return }
        Task { await generateAutoScene(state) }
    }

    /// 「現在用 AI 生成一組」。
    func generateAutoSceneNow(now: Date = Date()) async {
        let context = Self.plannerContext(prefs.defaults)
        await generateAutoScene(DynamicAutoPlanner.manual(state: DynamicAutoState.load(from: paths.dynamicAutoState), now: now,
                                                          frequency: dynamicAutoFrequency, southern: context.southern,
                                                          chinese: context.chinese))
    }

    nonisolated static func plannerContext(_ defaults: UserDefaults) -> (southern: Bool, chinese: Bool) {
        let southern = DynamicTiming.load(defaults) == .solar && Coordinate.load(defaults).0.latitude < 0
        return (southern, (Locale.preferredLanguages.first ?? "").hasPrefix("zh"))
    }

    func generateAutoScene(_ planned: DynamicAutoState) async {
        guard sceneProgress == nil else { return }
        let url = paths.dynamicAutoState
        var state = planned
        state.attempts += 1
        state.retryAfter = nil
        let counted = state
        do {
            let service = SceneGenerationService(provider: try provider(), paths: paths, target: DeviceScreen.nativePixels)
            sceneError = nil
            sceneProgress = 0
            defer { sceneProgress = nil; reload() }
            do {
                let record = try await GenerationLease.shared.run {
                    // 付費請求送出前先記次數。
                    try counted.save(to: url)
                    return try await service.generate(prompt: counted.prompt, id: counted.sceneID) { step in
                        Task { @MainActor in self.sceneProgress = step }
                    }
                }
                state.recordSuccess()
                try? state.save(to: url)
                dynamicSceneID = record.id
                prefs.dynamicSceneID = record.id
            } catch GenerationError.cooldown {
                return  // 另一個生成在跑（例如每日批次），下次打開再試，不算次數
            } catch {
                state.recordFailure(retryable: DynamicAutoState.isRetryable(error), now: Date())
                try? state.save(to: url)
                if !DynamicAutoState.isCancellation(error) {
                    sceneError = (error as? LocalizedError)?.errorDescription ?? L("生成失敗。")
                }
            }
        } catch {
            sceneError = (error as? LocalizedError)?.errorDescription ?? L("生成失敗。")
        }
    }

    func selectScene(_ id: String) {
        dynamicSceneID = id
        prefs.dynamicSceneID = id
    }

    // MARK: API key

    func saveKey(_ value: String) -> String? {
        do { try store.save(value); reload(); return nil }
        catch { return (error as? LocalizedError)?.errorDescription ?? L("儲存失敗。") }
    }

    func removeKey() {
        try? store.delete()
        reload()
    }
}

/// 同一時間只跑一個生成工作（前景與背景任務共用）。
actor GenerationLease {
    static let shared = GenerationLease()
    private var busy = false
    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        guard !busy else { throw GenerationError.cooldown }
        busy = true
        defer { busy = false }
        return try await work()
    }
}

/// 夜間補做：BGProcessingTask（需要網路）。不承諾準時。
enum BackgroundScheduler {
    static let identifier = "com.utuvo.wallpaper.daily"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handle(task)
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        var next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 3), matchingPolicy: .nextTime) ?? Date()
        if next.timeIntervalSinceNow < 60 { next = Date().addingTimeInterval(3600) }
        request.earliestBeginDate = next
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule()
        let prefs = Preferences()
        let paths = AppPaths.shared
        let day = AppPaths.dayString(Date())
        guard prefs.dailyEnabled, DailyGenerationService.hasWork(paths: paths, day: day),
              let provider = try? ProviderFactory.make() else {
            task.setTaskCompleted(success: true)
            return
        }
        let work = Task {
            let service = DailyGenerationService(provider: provider, paths: paths, target: DeviceScreen.nativePixels,
                                                 recipe: DailyRecipe.load(prefs.defaults))
            do {
                _ = try await GenerationLease.shared.run { try await service.run(day: day) }
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}

/// 只畫純色／漸層時用：本機規格在送出前就畫好，萬一被叫到就回報缺 key。
struct LocalOnlyProvider: ImageProvider {
    func generateImage(prompt: String) async throws -> Data { throw GenerationError.missingCredential }
    func relight(reference: Data, prompt: String) async throws -> Data { throw GenerationError.missingCredential }
}
