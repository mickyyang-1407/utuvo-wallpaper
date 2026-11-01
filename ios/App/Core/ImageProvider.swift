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
    static let generationsURL = URL(string: "https://api.openai.com/v1/images/generations")!
    static let editsURL = URL(string: "https://api.openai.com/v1/images/edits")!
    static let model = "gpt-image-2"
    static let size = "2160x3840"
    static let quality = "high"

    let apiKey: String
    let session: URLSession

    init(apiKey: String, timeout: TimeInterval = 180, configuration: URLSessionConfiguration = .ephemeral) {
        self.apiKey = apiKey
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
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
            (data, response) = try await session.data(for: request)
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
