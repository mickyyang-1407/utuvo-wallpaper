import XCTest
@testable import UTUVOWallpaper

/// 每日 10 張的變化、自選風格、自己的想法，以及日夜 AI 自動的排程（iPhone 端）。
final class VarietyTests: XCTestCase {
    var paths: AppPaths!
    let target = CGSize(width: 132, height: 287)

    override func setUp() { paths = makeTempPaths() }
    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func testDifferentDaysGetDifferentPrompts() async throws {
        let first = ScriptedProvider([])
        _ = try await DailyGenerationService(provider: first, paths: paths, target: target).run(day: "2026-11-02")
        let second = ScriptedProvider([])
        _ = try await DailyGenerationService(provider: second, paths: paths, target: target).run(day: "2026-11-03")
        XCTAssertEqual(Set(first.prompts).count, 10)
        XCTAssertTrue(Set(first.prompts).isDisjoint(with: second.prompts), "隔天 10 張提示詞都不同")
    }

    func testEachStyleCyclesThroughAllSubjectsBeforeRepeating() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3))!
        for template in PromptTemplate.shared {
            let picked = (0..<template.subjects.count).map { offset -> String in
                let day = formatter.string(from: calendar.date(byAdding: .day, value: offset, to: start)!)
                let prompt = DailyPlan.make(day: day, count: 10, recipe: DailyRecipe()).first { $0.templateID == template.id }!.prompt
                return template.subjects.first { prompt.contains("Subject: \($0).") } ?? "?"
            }
            XCTAssertEqual(Set(picked).count, template.subjects.count, template.id)
        }
    }

    func testIdeaAndStylesDriveThePortraitPrompts() async throws {
        let provider = ScriptedProvider([])
        let recipe = DailyRecipe(styles: ["watercolor-meadow", "animation-coast"], idea: "海邊的老火車站")
        _ = try await DailyGenerationService(provider: provider, paths: paths, target: target, recipe: recipe)
            .run(day: "2026-11-02", count: 4)
        XCTAssertEqual(provider.prompts.count, 4)
        XCTAssertTrue(provider.prompts.allSatisfy { $0.contains("海邊的老火車站") && $0.contains("9:16") && !$0.contains("16:9") })
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.wallpapers.path).sorted()
        XCTAssertEqual(files.count, 4)
        XCTAssertTrue(files.allSatisfy { $0.hasPrefix("watercolor-meadow") || $0.hasPrefix("animation-coast") }, "\(files)")
        XCTAssertTrue(files.allSatisfy { ["水彩", "動畫"].contains(WallpaperCategory.category(forFileName: $0)) })
    }

    func testResumeKeepsTheStoredPlanAfterSettingsChange() async throws {
        let failing = ScriptedProvider([.ok, .fail(.httpStatus(500))])
        let recipe = DailyRecipe(styles: [], idea: "雨後的竹林")
        do { _ = try await DailyGenerationService(provider: failing, paths: paths, target: target, recipe: recipe)
            .run(day: "2026-11-02", count: 3); XCTFail() } catch {}
        let stored = try DailyBatch.load(root: paths.root, day: "2026-11-02").plan
        XCTAssertEqual(stored?.count, 3)
        // 設定改成別的；同一批續作仍照原計畫。
        try DailyBatch.load(root: paths.root, day: "2026-11-02").with { $0.retryAfter = .distantPast }.save(root: paths.root, day: "2026-11-02")
        let resumed = ScriptedProvider([])
        _ = try await DailyGenerationService(provider: resumed, paths: paths, target: target,
                                             recipe: DailyRecipe(styles: ["gradient-tide"], idea: ""))
            .run(day: "2026-11-02", count: 3)
        XCTAssertTrue(resumed.prompts.allSatisfy { $0.contains("雨後的竹林") }, "\(resumed.prompts)")
    }

    func testRecipePersistsInDefaults() {
        let defaults = UserDefaults(suiteName: "test.recipe.\(UUID().uuidString)")!
        DailyRecipe(styles: ["cosmic-nebula", "bogus"], idea: "城市夜景").save(defaults)
        let loaded = DailyRecipe.load(defaults)
        XCTAssertEqual(loaded.styles, ["cosmic-nebula"])
        XCTAssertEqual(loaded.idea, "城市夜景")
        XCTAssertEqual(DynamicAutoFrequency.load(defaults), .off)
        DynamicAutoFrequency.weekly.save(defaults)
        XCTAssertEqual(DynamicAutoFrequency.load(defaults), .weekly)
    }

    func testAutoSceneScheduleOnPhone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!
        guard var state = DynamicAutoPlanner.due(state: nil, now: now, frequency: .daily, calendar: calendar, chinese: true) else {
            return XCTFail("第一次應該到期")
        }
        XCTAssertTrue(state.prompt.contains("秋天"))
        state.attempts = 1
        state.recordSuccess()
        XCTAssertNil(DynamicAutoPlanner.due(state: state, now: now.addingTimeInterval(3600), frequency: .daily, calendar: calendar, chinese: true))
        let tomorrow = DynamicAutoPlanner.due(state: state, now: now.addingTimeInterval(86_400), frequency: .daily, calendar: calendar, chinese: true)
        XCTAssertNotNil(tomorrow)
        XCTAssertNotEqual(tomorrow?.subject, state.subject)
        XCTAssertNil(DynamicAutoPlanner.due(state: nil, now: now, frequency: .off, calendar: calendar, chinese: true))
    }

    func testCancelledAutoSceneStaysResumable() {
        var state = DynamicAutoState(period: "2026-11-02", subject: "harbor", prompt: "p", sceneID: "ai-y")
        state.attempts = 1
        state.recordFailure(retryable: DynamicAutoState.isRetryable(GenerationError.cancelled), now: Date())
        XCTAssertEqual(state.attempts, 1)
        XCTAssertNotNil(state.retryAfter)
        XCTAssertTrue(DynamicAutoState.isCancellation(GenerationError.cancelled))
        XCTAssertFalse(DynamicAutoState.isRetryable(GenerationError.httpStatus(400)))
    }

    func testAutoSceneStateRoundTrip() throws {
        let url = paths.dynamicAutoState
        var state = DynamicAutoState(period: "2026-W45", subject: "lighthouse", prompt: "海岬岩岸上的白色燈塔，秋天，薄霧", sceneID: "ai-x")
        state.attempts = 1
        try state.save(to: url)
        XCTAssertEqual(DynamicAutoState.load(from: url), state)
    }
}

private extension DailyBatch {
    func with(_ change: (inout DailyBatch) -> Void) -> DailyBatch { var copy = self; change(&copy); return copy }
}
