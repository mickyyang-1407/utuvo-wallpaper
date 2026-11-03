import Foundation

/// 產生一張圖的抽象。正式環境用 OpenAI；測試與截圖用假 provider。
protocol ImageProvider: Sendable {
    /// 回傳原生 PNG。
    func generateImage(prompt: String) async throws -> Data
    /// 用同一張參考圖只換光線（`/v1/images/edits`）。
    func relight(reference: Data, prompt: String) async throws -> Data
}

/// OpenAI Images API（與 Mac 相同模型與規則；iPhone 改直式尺寸）。
/// - 每次只送一個請求（序列）。
/// - 錯誤只帶 HTTP 狀態碼；不記 body、header、key。
struct OpenAIImageProvider: ImageProvider {
    static var generationsURL: URL { base.appendingPathComponent("v1/images/generations") }
    static var editsURL: URL { base.appendingPathComponent("v1/images/edits") }
    private static var base: URL {
        #if DEBUG
        // Debug 專用：`-UTUVOAPIBase http://127.0.0.1:PORT` 指到本機假伺服器測連線（Release 不編入）。
        if let text = UserDefaults.standard.string(forKey: "UTUVOAPIBase"), let url = URL(string: text) { return url }
        #endif
        return URL(string: "https://api.openai.com")!
    }
    static let model = "gpt-image-2"
    static let size = "2160x3840"
    static let quality = "high"

    let apiKey: String
    let session: URLSession
    /// 送生圖請求用的通道。正式環境走背景 session：切到別的 App 時請求不會斷。
    let transfer: ImageTransfer

    /// `background` false＝生圖請求也走 `configuration` 這個一般 session（測試用 stub）。
    init(apiKey: String, timeout: TimeInterval = 180, configuration: URLSessionConfiguration = .ephemeral,
         background: Bool = true) {
        self.apiKey = apiKey
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        self.session = session
        self.transfer = background ? BackgroundTransfer.shared : SessionTransfer(session: session)
    }

    static func validatePrompt(_ prompt: String) throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GenerationError.emptyPrompt }
        return trimmed
    }

    func makeGenerationRequest(prompt: String) throws -> URLRequest {
        let trimmed = try Self.validatePrompt(prompt)
        var request = URLRequest(url: Self.generationsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": Self.model, "prompt": trimmed, "size": Self.size,
                                   "quality": Self.quality, "n": 1, "output_format": "png"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func makeEditRequest(reference: Data, prompt: String) throws -> URLRequest {
        let trimmed = try Self.validatePrompt(prompt)
        let boundary = "UTUVO-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (key, value) in [("model", Self.model), ("size", Self.size), ("quality", Self.quality),
                             ("output_format", "png"), ("n", "1"), ("prompt", trimmed)] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"reference.png\"\r\nContent-Type: image/png\r\n\r\n")
        body.append(reference)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: Self.editsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func generateImage(prompt: String) async throws -> Data {
        try await send(makeGenerationRequest(prompt: prompt))
    }

    func relight(reference: Data, prompt: String) async throws -> Data {
        try await send(makeEditRequest(reference: reference, prompt: prompt))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transfer.send(request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw GenerationError.cancelled
            case .timedOut: throw GenerationError.timeout
            default: throw GenerationError.transport
            }
        } catch is CancellationError {
            throw GenerationError.cancelled
        } catch {
            throw GenerationError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw GenerationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw GenerationError.httpStatus(http.statusCode) }
        return try await extractImage(from: data)
    }

    /// 支援 b64_json 與 url 兩種回應。
    func extractImage(from data: Data) async throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]], let first = items.first else {
            throw GenerationError.invalidResponse
        }
        if let b64 = first["b64_json"] as? String, let decoded = Data(base64Encoded: b64) { return decoded }
        if let string = first["url"] as? String, let url = URL(string: string), url.scheme == "https" {
            let remote: Data, response: URLResponse
            do { (remote, response) = try await session.data(from: url) } catch { throw GenerationError.transport }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw GenerationError.httpStatus(http.statusCode)
            }
            return remote
        }
        throw GenerationError.invalidResponse
    }
}

/// 送一個請求、拿回整個回應。
protocol ImageTransfer: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

struct SessionTransfer: ImageTransfer {
    let session: URLSession
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) { try await session.data(for: request) }
}

/// 背景 URLSession：一張圖要 1–3 分鐘，使用者切到別的 App 時 iOS 會暫停 App，一般連線就斷了。
/// 背景 session 由系統代為收送，App 回到前景時接著拿到結果。
/// 請求本文先寫到暫存檔（背景 session 只接受從檔案上傳）。
final class BackgroundTransfer: NSObject, ImageTransfer, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "com.utuvo.wallpaper.images"
    static let shared = BackgroundTransfer(configuration: .background(withIdentifier: identifier))

    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    private var waiters: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private var session: URLSession!
    /// 這次啟動送出的請求都標上它。上次啟動留下、已經沒人在等的請求（App 被系統關掉時系統會繼續送、
    /// 斷線還會自己重送）一律取消，免得多付一張拿不到的圖。
    private let launchToken = UUID().uuidString

    init(configuration: URLSessionConfiguration) {
        super.init()
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = false
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let token = launchToken
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription != token { task.cancel() }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        try (request.httpBody ?? Data()).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var bare = request
        bare.httpBody = nil
        let task = session.uploadTask(with: bare, fromFile: file)
        task.taskDescription = launchToken
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { waiters[task.taskIdentifier] = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { buffers[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (waiter, data) = lock.withLock {
            (waiters.removeValue(forKey: task.taskIdentifier), buffers.removeValue(forKey: task.taskIdentifier) ?? Data())
        }
        guard let waiter else { return }
        if let error { waiter.resume(throwing: error) }
        else if let response = task.response { waiter.resume(returning: (data, response)) }
        else { waiter.resume(throwing: URLError(.badServerResponse)) }
    }
}
