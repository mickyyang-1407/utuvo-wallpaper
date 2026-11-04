import Foundation
import CoreGraphics

// MARK: - Provider 協定

/// 產生一張圖的抽象。正式環境用 OpenAI；自我測試用 fixture，兩者走同一條下游流程。
protocol ImageProvider: Sendable {
    /// 回傳 PNG 資料（原生）。
    func generateImage(prompt: String) async throws -> Data
}

// MARK: - OpenAI 實作

/// 正式產品的圖片產生器。
///
/// 規則：
/// - 每次只送一個請求（序列），不做自動重試（避免重複計費）。
/// - 不輸出 raw response / headers / key。錯誤只帶 HTTP 狀態碼。
struct OpenAIImageProvider: ImageProvider {
    static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!
    static let model = "gpt-image-2"
    // Official Images API size limit; 6K is produced locally by resampling.
    // https://developers.openai.com/api/reference/resources/images/methods/generate
    static let size = "3840x2160"
    static let quality = "high"

    let apiKey: String
    let session: URLSession

    init(apiKey: String, timeout: TimeInterval = 180) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func generateImage(prompt: String) async throws -> Data {
        let trimmed = try Self.validatePrompt(prompt)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": Self.model,
            "prompt": trimmed,
            "size": Self.size,
            "quality": Self.quality,
            "n": 1,
            "output_format": "png"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            LabLog.generate.error("image request URL error code=\(error.code.rawValue, privacy: .public)")
            switch error.code {
            case .cancelled: throw GenerationError.cancelled
            case .timedOut: throw GenerationError.timeout
            default: throw GenerationError.transport
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw GenerationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // 只記狀態碼，不記 body、不記 header。
            LabLog.generate.error("image request failed status=\(http.statusCode, privacy: .public)")
            throw GenerationError.httpStatus(http.statusCode)
        }

        return try Self.extractImage(from: data)
    }

    /// 檢查提示詞；空白直接拒絕（送出前就擋下，不浪費額度）。
    static func validatePrompt(_ prompt: String) throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GenerationError.emptyPrompt }
        return trimmed
    }

    /// 從回應 JSON 取出圖片資料。支援 b64_json 與 url 兩種形式。
    static func extractImage(from data: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]],
              let first = items.first else {
            throw GenerationError.invalidResponse
        }
        if let b64 = first["b64_json"] as? String, let decoded = Data(base64Encoded: b64) {
            return decoded
        }
        if let urlString = first["url"] as? String, let url = URL(string: urlString) {
            guard let (remote, response) = try? downloadSynchronously(url) else { throw GenerationError.invalidResponse }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw GenerationError.httpStatus(http.statusCode)
            }
            return remote
        }
        throw GenerationError.invalidResponse
    }

    /// 下載 API 回傳的圖片網址（同步版，避免在 static 函式內混用 async）。
    private static func downloadSynchronously(_ url: URL) throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let semaphore = DispatchSemaphore(value: 0)
        var out: (Data, URLResponse)?
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { failure = error } else if let data { out = (data, response ?? URLResponse()) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let failure { throw failure }
        guard let out else { throw GenerationError.invalidResponse }
        return out
    }
}

// MARK: - 生成流程

/// 一次生成下來的結果。
struct GeneratedWallpaper: Sendable, Codable {
    let title: String
    let nativeURL: String
    let nativePixelSize: String
    let wallpaperURL: String
    let wallpaperPixelSize: String
    let origin: String
}

/// 生成服務：手動與每日排程共用同一條路徑。
struct GenerationService: Sendable {
    let provider: ImageProvider
    /// 每日風格／自己的想法（AppModel 從偏好設定帶入）。
    var recipe = DailyRecipe()

    /// 產生 `count` 張。每完成一張立刻寫檔，不覆蓋既有檔案。
    /// - Parameters:
    ///   - outputRoot: 交付根目錄，底下會有 `originals/`（原生 PNG）與 `wallpapers/`（6K）。
    ///   - progress: 每完成一張回報進度（1-based）。
    func generate(count: Int,
                  outputRoot: URL,
                  batchDay: String? = nil,
                  progress: @Sendable (Int, Int) -> Void) async throws -> [GeneratedWallpaper] {
        guard count > 0 else { throw GenerationError.emptyPrompt }
        var batch = try batchDay.map {
            try DailyBatch.prepare(root: outputRoot, day: $0, count: count,
                                   plan: DailyPlan.make(day: $0, count: count, recipe: recipe))
        }
        // 手動生成每次都換一組（加上隨機 salt）。
        let plan = batch.map { $0.prompts(day: batchDay!) }
            ?? DailyPlan.make(day: DynamicAutoPlanner.period(for: Date(), frequency: .daily) ?? "manual",
                              count: count, recipe: recipe, salt: UUID().uuidString)
        var results: [GeneratedWallpaper] = batch?.completed ?? []
        progress(results.count, count)

        for index in results.count..<count {
            try Task.checkCancellation()
            let planned = plan[index]
            LabLog.generate.info("generating image \(index + 1)/\(count) template=\(planned.slug, privacy: .public)")

            let id = batchDay.map { "daily-" + $0 } ?? RandomID.make()
            let slug = planned.slug
            let originalsDir = outputRoot.appendingPathComponent("originals", isDirectory: true)
            let wallpapersDir = outputRoot.appendingPathComponent("wallpapers", isDirectory: true)
            let nativeURL = originalsDir.appendingPathComponent("\(slug)-\(id).png")
            let wallpaperURL = wallpapersDir.appendingPathComponent("\(slug)-\(id)-6k.jpg")

            let png: Data
            if batchDay != nil, FileManager.default.fileExists(atPath: nativeURL.path) {
                png = try Data(contentsOf: nativeURL)
            } else if LocalArt.isLocal(planned.prompt) {
                // 純色／漸層：本機畫原生 3840 × 2160，不送 API、不記重試次數。
                guard let drawn = LocalArt.render(planned.prompt, width: 3840, height: 2160) else { throw GenerationError.decoding }
                png = drawn
            } else {
                if let day = batchDay {
                    guard batch!.canResume() else { throw GenerationError.transport }
                    batch!.attempts[index] += 1
                    batch!.retryAfter = Date().addingTimeInterval(300)
                    try batch!.save(root: outputRoot, day: day)
                }
                do {
                    png = try await provider.generateImage(prompt: planned.prompt)
                    // 解碼失敗不可重試：走同一段 catch 停住這一批，不再付費重打。
                    guard ImageResampler.pixelSize(of: png) != nil else { throw GenerationError.decoding }
                } catch {
                    if let day = batchDay {
                        batch!.retryAfter = DailyBatch.isRetryable(error) && batch!.attempts[index] < 3
                            ? Date().addingTimeInterval(batch!.attempts[index] == 1 ? 60 : 300) : nil
                        try batch!.save(root: outputRoot, day: day)
                    }
                    throw error
                }
            }
            guard let size = ImageResampler.pixelSize(of: png) else { throw GenerationError.decoding }
            try ImageResampler.writePNG(png, to: nativeURL)
            let jpeg = try ImageResampler.resampleToJPEG6K(pngData: png)
            try ImageResampler.writeJPEG(jpeg, to: wallpaperURL)

            // provenance sidecar：原生與 6K 各寫各的。
            // 原生 PNG 標 native、6K 成品標 resampled，兩個 sidecar 檔名不同，
            // 否則讀取端會把原生圖誤標成「重採樣」。
            let nativeSize = "\(Int(size.width))x\(Int(size.height))"
            Self.writeProvenance([
                "origin": "native",
                "originLabel": ImageOrigin.native.label,
                "sourceNativeSize": nativeSize,
                "outputSize": nativeSize,
                "method": "AI generated native output (no resampling)"
            ], beside: nativeURL)
            Self.writeProvenance([
                "origin": "resampled",
                "originLabel": ImageOrigin.resampled.label,
                "sourceNativeSize": nativeSize,
                "outputSize": "6144x3456",
                "method": "CoreGraphics high-quality resample (not native, not AI upscale)"
            ], beside: wallpaperURL)

            results.append(GeneratedWallpaper(
                title: planned.title,
                nativeURL: nativeURL.path,
                nativePixelSize: "\(Int(size.width)) × \(Int(size.height))",
                wallpaperURL: wallpaperURL.path,
                wallpaperPixelSize: "6144 × 3456",
                origin: ImageOrigin.resampled.label
            ))
            if let day = batchDay {
                batch!.completed = results
                batch!.retryAfter = results.count < count ? Date() : nil
                try batch!.save(root: outputRoot, day: day)
            }
            progress(index + 1, count)
        }
        return results
    }

    /// 寫 provenance sidecar 到指定檔案旁（檔名 `<同名>.provenance.json`）。
    private static func writeProvenance(_ payload: [String: Any], beside url: URL) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? json.write(to: url.deletingPathExtension()
            .appendingPathExtension("provenance.json"), options: .atomic)
    }
}
