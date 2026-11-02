import CoreGraphics
import Foundation

/// 每日批次：每天最多一批 10 張（與 Mac 共用 `DailyPlan`：每天換主題、配色、光線、構圖，可選風格或自己的想法）。
/// 共用 `DailyBatch` 做進度檔：請求前先記次數；暫時性錯誤最多 3 次、60 秒／300 秒冷卻。
struct DailyGenerationService: Sendable {
    static let batchSize = 10
    let provider: ImageProvider
    let paths: AppPaths
    let target: CGSize
    var now: @Sendable () -> Date = { Date() }
    var recipe = DailyRecipe()

    func run(day: String, count: Int = DailyGenerationService.batchSize,
             progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [GeneratedWallpaper] {
        guard count > 0 else { throw GenerationError.emptyPrompt }
        paths.prepare()
        var batch = try DailyBatch.prepare(root: paths.root, day: day, count: count,
                                           plan: DailyPlan.make(day: day, count: count, recipe: recipe))
        let plan = batch.prompts(day: day)
        var results = batch.completed
        progress(results.count, count)

        for index in results.count..<count {
            try Task.checkCancellation()
            let planned = plan[index]
            let nativeURL = paths.originals.appendingPathComponent("\(planned.slug)-daily-\(day).png")
            let wallpaperURL = paths.wallpapers.appendingPathComponent("\(planned.slug)-daily-\(day).jpg")

            let png: Data
            if FileManager.default.fileExists(atPath: nativeURL.path) {
                png = try Data(contentsOf: nativeURL)
            } else if LocalArt.isLocal(planned.prompt) {
                // 純色／漸層：本機直接畫成手機尺寸，不送 API。
                guard let drawn = LocalArt.render(planned.prompt, width: Int(target.width), height: Int(target.height)) else {
                    throw GenerationError.decoding
                }
                png = drawn
                try ImageProcessing.write(png, to: nativeURL)
            } else {
                guard batch.canResume(at: now()) else { throw GenerationError.cooldown }
                // 先記次數再送出：當機也不會重置重試額度。
                batch.attempts[index] += 1
                batch.retryAfter = now().addingTimeInterval(300)
                try batch.save(root: paths.root, day: day)
                do {
                    png = try await provider.generateImage(prompt: PortraitPrompt.convert(planned.prompt))
                } catch {
                    batch.retryAfter = DailyBatch.isRetryable(error) && batch.attempts[index] < 3
                        ? now().addingTimeInterval(batch.attempts[index] == 1 ? 60 : 300) : nil
                    try batch.save(root: paths.root, day: day)
                    throw error
                }
                guard ImageProcessing.pixelSize(of: png) != nil else { throw GenerationError.decoding }
                try ImageProcessing.write(png, to: nativeURL)
                AppPaths.excludeFromBackup(paths.originals)
            }
            guard let size = ImageProcessing.pixelSize(of: png) else { throw GenerationError.decoding }
            let jpeg = try ImageProcessing.cropToJPEG(imageData: png, target: target)
            try ImageProcessing.write(jpeg, to: wallpaperURL)

            results.append(GeneratedWallpaper(
                title: planned.title,
                nativeURL: nativeURL.lastPathComponent,
                nativePixelSize: CropMath.label(size),
                wallpaperURL: wallpaperURL.lastPathComponent,
                wallpaperPixelSize: CropMath.label(target),
                origin: "resampled"))
            batch.completed = results
            batch.retryAfter = results.count < count ? now() : nil
            try batch.save(root: paths.root, day: day)
            progress(results.count, count)
        }
        return results
    }

    /// 今天是否還有工作可做（未建立、或可續作）。
    static func hasWork(paths: AppPaths, day: String, at date: Date = Date()) -> Bool {
        let url = DailyBatch.url(root: paths.root, day: day)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? DailyBatch.load(root: paths.root, day: day).canResume(at: date)) == true
    }

    static func status(paths: AppPaths, day: String) -> (done: Int, total: Int)? {
        guard let batch = try? DailyBatch.load(root: paths.root, day: day) else { return nil }
        return (batch.completed.count, batch.count)
    }
}

/// 日夜場景：白天生成 → 同一張白天 PNG 做 3 次 edits（清晨／黃昏／夜晚）→ 四張都裁成裝置尺寸。
/// 全部完成才寫 `dynamic/current.json` 發布。
struct SceneRecord: Codable, Equatable, Sendable {
    var id: String
    var prompt: String
    var completed: Bool
}

struct SceneGenerationService: Sendable {
    let provider: ImageProvider
    let paths: AppPaths
    let target: CGSize

    static let relightOrder: [DayPhase] = [.dawn, .dusk, .night]

    func directory(for id: String) -> URL { paths.dynamic.appendingPathComponent(id, isDirectory: true) }

    func generate(prompt rawPrompt: String, id: String = "scene-" + RandomID.make(),
                  progress: @Sendable (Int) -> Void = { _ in }) async throws -> SceneRecord {
        let prompt = try OpenAIImageProvider.validatePrompt(rawPrompt)
        paths.prepare()
        let dir = directory(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var record = SceneRecord(id: id, prompt: prompt, completed: false)
        let manifest = dir.appendingPathComponent("scene.json")
        if let data = try? Data(contentsOf: manifest), let old = try? JSONDecoder().decode(SceneRecord.self, from: data) {
            guard old.prompt == prompt else { throw GenerationError.invalidResponse }
        } else {
            try ImageProcessing.write(try JSONEncoder().encode(record), to: manifest)
        }

        let baseURL = dir.appendingPathComponent("day.png")
        let base: Data
        if let existing = try? Data(contentsOf: baseURL) { base = existing } else {
            base = try await provider.generateImage(prompt: DayPhase.basePrompt(scene: prompt))
            guard ImageProcessing.pixelSize(of: base) != nil else { throw GenerationError.decoding }
            try ImageProcessing.write(base, to: baseURL)
            AppPaths.excludeFromBackup(baseURL)
        }
        try ImageProcessing.write(try ImageProcessing.cropToJPEG(imageData: base, target: target),
                                  to: dir.appendingPathComponent("day.jpg"))
        progress(1)
        for (offset, phase) in Self.relightOrder.enumerated() {
            try Task.checkCancellation()
            let native = dir.appendingPathComponent(phase.rawValue + ".png")
            let png: Data
            if let existing = try? Data(contentsOf: native) { png = existing } else {
                png = try await provider.relight(reference: base, prompt: phase.relightPrompt)
                guard ImageProcessing.pixelSize(of: png) != nil else { throw GenerationError.decoding }
                try ImageProcessing.write(png, to: native)
                AppPaths.excludeFromBackup(native)
            }
            try ImageProcessing.write(try ImageProcessing.cropToJPEG(imageData: png, target: target),
                                      to: dir.appendingPathComponent(phase.rawValue + ".jpg"))
            progress(offset + 2)
        }
        record.completed = true
        try ImageProcessing.write(try JSONEncoder().encode(record), to: manifest)
        try ImageProcessing.write(try JSONEncoder().encode(record), to: paths.currentScenePointer)
        return record
    }

    static func published(paths: AppPaths) -> SceneRecord? {
        guard let data = try? Data(contentsOf: paths.currentScenePointer),
              let record = try? JSONDecoder().decode(SceneRecord.self, from: data), record.completed else { return nil }
        return record
    }
}
