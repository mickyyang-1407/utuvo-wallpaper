import Foundation

/// Saved under the generation lease. Attempts are committed before sending a
/// paid request, so a crash cannot reset the retry budget.
struct DailyBatch: Codable {
    var count: Int
    var completed: [GeneratedWallpaper] = []
    var attempts: [Int]
    var retryAfter: Date? = Date()
    /// 這一批的提示詞（建立時就定好，續作照用）；舊版進度檔沒有。
    var plan: [PlannedPrompt]?

    static func url(root: URL, day: String) -> URL {
        root.appendingPathComponent("daily-\(day).json")
    }
    static func load(root: URL, day: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url(root: root, day: day)))
    }
    static func prepare(root: URL, day: String, count: Int, plan: [PlannedPrompt]? = nil) throws -> Self {
        if FileManager.default.fileExists(atPath: url(root: root, day: day).path) {
            let batch = try load(root: root, day: day)
            guard batch.count == count, batch.attempts.count == count,
                  batch.completed.count <= count else { throw GenerationError.invalidResponse }
            return batch
        }
        let batch = Self(count: count, attempts: Array(repeating: 0, count: count), plan: plan)
        try batch.save(root: root, day: day)
        return batch
    }
    /// 這一批要生成的內容：有存就照存的，舊檔照舊輪替。
    func prompts(day: String) -> [PlannedPrompt] {
        if let plan, plan.count == count { return plan }
        return DailyPlan.legacy(day: day, count: count)
    }
    func save(root: URL, day: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url(root: root, day: day), options: .atomic)
    }
    func canResume(at date: Date = Date()) -> Bool {
        guard completed.count < count, attempts.count == count, let retryAfter else { return false }
        return retryAfter <= date && attempts[completed.count] < 3
    }
    static func canResume(root: URL, day: String) -> Bool {
        (try? load(root: root, day: day).canResume()) == true
    }
    static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? GenerationError else { return false }
        switch error {
        case .transport, .timeout: return true
        case .httpStatus(let code): return code == 429 || (500...599).contains(code)
        default: return false
        }
    }
}
