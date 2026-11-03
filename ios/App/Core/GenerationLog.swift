import Foundation

/// 每一次送出的生圖請求結果，用來算成功率。
/// 只記時間、種類、結果代碼和秒數；不記提示詞、key 或回應內容。
struct GenerationLogEntry: Codable, Equatable, Sendable {
    var at: Date
    /// generate（新圖）或 relight（日夜換光線）。
    var kind: String
    /// ok、http-429、timeout、transport、cancelled、decoding…
    var outcome: String
    var seconds: Double

    var succeeded: Bool { outcome == "ok" }
}

enum GenerationLog {
    static let limit = 300
    private static let lock = NSLock()

    static func url(_ paths: AppPaths) -> URL { paths.root.appendingPathComponent("generation-log.json") }

    static func load(_ paths: AppPaths) -> [GenerationLogEntry] {
        guard let data = try? Data(contentsOf: url(paths)) else { return [] }
        return (try? JSONDecoder().decode([GenerationLogEntry].self, from: data)) ?? []
    }

    static func append(_ entry: GenerationLogEntry, paths: AppPaths) {
        lock.withLock {
            var entries = load(paths)
            entries.append(entry)
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
            try? JSONEncoder().encode(entries).write(to: url(paths), options: .atomic)
        }
    }

    static func outcome(of error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? GenerationError else { return "other" }
        switch error {
        case .httpStatus(let code): return "http-\(code)"
        case .timeout: return "timeout"
        case .transport: return "transport"
        case .cancelled: return "cancelled"
        case .decoding: return "decoding"
        case .invalidResponse: return "invalid-response"
        default: return "other"
        }
    }

    struct Summary: Equatable {
        var succeeded: Int
        var total: Int
        /// 失敗原因與次數，次數多的在前。
        var failures: [(outcome: String, count: Int)]

        static func == (a: Summary, b: Summary) -> Bool {
            a.succeeded == b.succeeded && a.total == b.total
                && a.failures.map(\.outcome) == b.failures.map(\.outcome) && a.failures.map(\.count) == b.failures.map(\.count)
        }
    }

    /// 最近 `days` 天的成功率。沒有請求回 nil。
    static func summary(_ entries: [GenerationLogEntry], days: Int = 7, now: Date = Date()) -> Summary? {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = entries.filter { $0.at >= since }
        guard !recent.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for entry in recent where !entry.succeeded { counts[entry.outcome, default: 0] += 1 }
        let failures = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (outcome: $0.key, count: $0.value) }
        return Summary(succeeded: recent.filter(\.succeeded).count, total: recent.count, failures: failures)
    }

    /// 給人看的失敗原因。
    static func label(_ outcome: String) -> String {
        switch outcome {
        case "timeout": return L("逾時")
        case "transport": return L("連線中斷")
        case "cancelled": return L("被中斷")
        case "http-429": return L("額度或限流")
        case "decoding", "invalid-response": return L("回應無法解析")
        default:
            if outcome.hasPrefix("http-") { return "HTTP " + outcome.dropFirst(5) }
            return L("其他")
        }
    }
}

/// 包住真的 provider，每個請求記一筆結果。
struct LoggingImageProvider: ImageProvider {
    let base: ImageProvider
    let paths: AppPaths
    var now: @Sendable () -> Date = { Date() }

    func generateImage(prompt: String) async throws -> Data {
        try await record("generate") { try await base.generateImage(prompt: prompt) }
    }

    func relight(reference: Data, prompt: String) async throws -> Data {
        try await record("relight") { try await base.relight(reference: reference, prompt: prompt) }
    }

    private func record(_ kind: String, _ work: () async throws -> Data) async throws -> Data {
        let start = now()
        do {
            let data = try await work()
            GenerationLog.append(.init(at: start, kind: kind, outcome: "ok", seconds: now().timeIntervalSince(start)), paths: paths)
            return data
        } catch GenerationError.emptyPrompt {
            throw GenerationError.emptyPrompt  // 沒送出請求，不算
        } catch {
            GenerationLog.append(.init(at: start, kind: kind, outcome: GenerationLog.outcome(of: error),
                                       seconds: now().timeIntervalSince(start)), paths: paths)
            throw error
        }
    }
}
