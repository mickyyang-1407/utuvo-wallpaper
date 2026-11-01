import Foundation

struct BackgroundSnapshot: Codable {
    var updatedAt = Date()
    var stage = "待命"
    var progress = ""
    var message = ""
    var error: String?
    var lastBatchDate: Date?
    var lastBatchCount = 0

    static var url: URL { LabPaths.deliveryRoot.appendingPathComponent("background-status.json") }

    /// stage 以繁中原文寫入狀態檔，顯示時才翻譯。
    static func stageTitle(_ stage: String) -> String {
        switch stage {
        case "待命": return L("待命")
        case "生成中": return L("生成中")
        case "需要處理": return L("需要處理")
        default: return stage
        }
    }

    static func load() -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

/// launchd runs this entry point without a window. One tick owns its lease until
/// generation and desktop readback finish; subsequent minutes cannot overlap.
@MainActor
enum BackgroundRunner {
    static func tick() async -> Int32 {
        guard BackgroundService.isEnabled() else { return 0 }
        do {
            guard let lease = try FileLease.acquire(at: LabPaths.deliveryRoot.appendingPathComponent(".background-tick.lock")) else { return 0 }
            defer { withExtendedLifetime(lease) {} }
            let model = AppModel(isBackgroundWorker: true)
            var snapshot = BackgroundSnapshot.load() ?? BackgroundSnapshot()
            if model.isDynamicActive { await model.performBackgroundRotation(at: Date()) }
            model.checkDaily()
            let attempted = model.isGenerating
            if attempted { snapshot.error = nil }
            while model.isGenerating {
                if model.isDynamicActive { await model.performBackgroundRotation(at: Date()) }
                snapshot.updatedAt = Date()
                snapshot.stage = "生成中"
                snapshot.progress = model.generationProgress
                try snapshot.save()
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if attempted {
                snapshot.lastBatchCount = model.lastGeneratedCount
                snapshot.lastBatchDate = Date()
                snapshot.message = model.statusMessage
                snapshot.error = model.errorMessage
            } else if let error = model.errorMessage {
                snapshot.error = error
            }
            // A fresh process reads the persisted rotation cursor and timestamp.
            // Recording failed readback also spaces out attempts by the interval.
            model.errorMessage = nil
            await model.performBackgroundRotation(at: Date())
            if let error = model.errorMessage { snapshot.error = error }
            snapshot.updatedAt = Date()
            snapshot.stage = snapshot.error == nil ? "待命" : "需要處理"
            snapshot.progress = ""
            if model.statusMessage != AppModel.readyMessage {
                snapshot.message = model.statusMessage
            }
            try snapshot.save()
            return snapshot.error == nil ? 0 : 1
        } catch {
            var snapshot = BackgroundSnapshot.load() ?? BackgroundSnapshot()
            snapshot.updatedAt = Date()
            snapshot.stage = "需要處理"
            snapshot.error = L("背景作業無法完成，請檢查資料夾權限或重新開啟 App。")
            try? snapshot.save()
            return 1
        }
    }
}
