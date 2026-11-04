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
        _ = try await DailyGenerationService(provider: first, paths: paths, target: target, recipe: DailyRecipe(styles: PromptTemplate.shared.filter { $0.local == nil }.map(\.id))).run(day: "2026-11-02")
        let second = ScriptedProvider([])
        _ = try await DailyGenerationService(provider: second, paths: paths, target: target, recipe: DailyRecipe(styles: PromptTemplate.shared.filter { $0.local == nil }.map(\.id))).run(day: "2026-11-03")
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
            let pool = DailyPlan.subjectPool(template)
            let picked = (0..<pool.count).map { offset -> String in
                let day = formatter.string(from: calendar.date(byAdding: .day, value: offset, to: start)!)
                let prompt = DailyPlan.make(day: day, count: 1, recipe: DailyRecipe(styles: [template.id])).first!.prompt
                return pool.first { prompt.contains("Subject: \($0).") } ?? "?"
            }
            XCTAssertEqual(Set(picked).count, pool.count, template.id)
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
        let recipe = DailyRecipe(styles: PromptTemplate.shared.filter { $0.local == nil }.map(\.id), idea: "雨後的竹林")
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

    func testCategorySelectionMapsToStyles() {
        var recipe = DailyRecipe()
        recipe.setCategory("抽象", on: true)
        XCTAssertEqual(recipe.categories, ["抽象"])
        XCTAssertTrue(recipe.templates.allSatisfy { $0.category == "抽象" })
        XCTAssertEqual(recipe.templates.count, PromptTemplate.shared.filter { $0.category == "抽象" }.count)
        recipe.setCategory("抽象", on: false)
        XCTAssertTrue(recipe.styles.isEmpty)
        XCTAssertEqual(DailyRecipe.categories.first, "自然")
    }

    func testInspirationRespectsCategoryAndChangesText() {
        let current = PromptInspiration.ideas["建築"]![0].zh
        for _ in 0..<20 {
            let idea = PromptInspiration.pick(categories: ["建築"], current: current, chinese: true)
            XCTAssertNotEqual(idea, current)
            XCTAssertTrue(PromptInspiration.ideas["建築"]!.map(\.zh).contains { idea.hasPrefix($0) }, idea)
        }
    }

    func testLocalStylesDrawWithoutCallingTheAPI() async throws {
        let provider = ScriptedProvider([])
        let results = try await DailyGenerationService(provider: provider, paths: paths, target: target,
                                                       recipe: DailyRecipe(styles: ["solid-color", "gradient-soft"]))
            .run(day: "2026-11-03", count: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(provider.prompts.isEmpty, "純色／漸層不送 API")
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.wallpapers.path)
        XCTAssertEqual(files.count, 3)
        for name in files { XCTAssertEqual(ImageProcessing.pixelSize(at: paths.wallpapers.appendingPathComponent(name)), target) }
    }

    func testManualGenerateMakesNewSetWithoutTouchingDailyBatch() async throws {
        let aiStyles = DailyRecipe(styles: PromptTemplate.shared.filter { $0.local == nil }.map(\.id), idea: "")
        let first = ScriptedProvider([])
        let made = try await DailyGenerationService(provider: first, paths: paths, target: target, recipe: aiStyles)
            .runManual(count: 3)
        let second = ScriptedProvider([])
        _ = try await DailyGenerationService(provider: second, paths: paths, target: target, recipe: aiStyles)
            .runManual(count: 3)
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(first.prompts.count, 3)
        XCTAssertNotEqual(first.prompts, second.prompts, "每按一次換一組")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DailyBatch.url(root: paths.root, day: "2026-11-02").path))
        XCTAssertTrue(DailyGenerationService.hasWork(paths: paths, day: AppPaths.dayString(Date())), "不佔每天那一批")
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.wallpapers.path)
        XCTAssertEqual(files.count, 6)
        for name in files {
            XCTAssertNotEqual(WallpaperCategory.category(forFileName: name), WallpaperCategory.other, name)
            XCTAssertEqual(ImageProcessing.pixelSize(at: paths.wallpapers.appendingPathComponent(name)), target)
        }
    }

    func testManualGenerateHonorsCategoryAndIdea() async throws {
        let provider = ScriptedProvider([])
        var recipe = DailyRecipe(idea: "雨夜的便利商店")
        recipe.setCategory("城市", on: true)
        _ = try await DailyGenerationService(provider: provider, paths: paths, target: target, recipe: recipe).runManual(count: 2)
        XCTAssertTrue(provider.prompts.allSatisfy { $0.contains("雨夜的便利商店") && $0.contains("9:16") })
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.wallpapers.path)
        XCTAssertTrue(files.allSatisfy { WallpaperCategory.category(forFileName: $0) == "城市" }, "\(files)")
    }

    func testManualGenerateLocalOnlyNeedsNoAPIAndKeepsDoneOnFailure() async throws {
        let local = ScriptedProvider([])
        _ = try await DailyGenerationService(provider: local, paths: paths, target: target,
                                             recipe: DailyRecipe(styles: ["solid-color", "gradient-soft"])).runManual(count: 2)
        XCTAssertTrue(local.prompts.isEmpty)
        let failing = ScriptedProvider([.ok, .fail(.httpStatus(500))])
        do {
            _ = try await DailyGenerationService(provider: failing, paths: paths, target: target,
                                                 recipe: DailyRecipe(styles: ["city"])).runManual(count: 3)
            XCTFail("第二張應該失敗")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.wallpapers.path).count, 3, "完成的那張保留")
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

final class WiderPromptTests: XCTestCase {
    /// 只選一個分類一次產 10 張：10 個主題都不同，而且一半左右帶氣氛細節。
    func testOneCategoryTenImagesAllDiffer() {
        for category in ["動物", "城市", "動畫", "抽象"] {
            var recipe = DailyRecipe()
            recipe.setCategory(category, on: true)
            let plan = DailyPlan.make(day: "2026-11-04", count: 10, recipe: recipe, salt: "manual-1")
            let subjects = plan.map { $0.prompt.components(separatedBy: "Subject: ")[1].components(separatedBy: ". ")[0] }
            XCTAssertEqual(Set(subjects).count, 10, "\(category): \(subjects)")
            XCTAssertGreaterThanOrEqual(Set(plan.map(\.prompt)).count, 10)
        }
        let pool = DailyPlan.subjectPool(PromptTemplate.shared.first { $0.id == "animals" }!)
        XCTAssertGreaterThanOrEqual(pool.count, 25)
    }

    func testPortraitSaysVerticalOnceAndDoesNotPinTheSubject() {
        let plan = DailyPlan.make(day: "2026-11-04", count: 10, recipe: DailyRecipe())
        for planned in plan {
            let out = PortraitPrompt.convert(planned.prompt)
            XCTAssertEqual(out.components(separatedBy: "vertical 9:16 iPhone wallpaper").count - 1, 1, out)
            XCTAssertFalse(out.contains("lower two thirds"), out)
            XCTAssertTrue(out.contains(PortraitPrompt.clockSentence), out)
        }
    }
}

final class MixedStyleTests: XCTestCase {
    func testContentCategoriesMixArtStylesButStyleCategoriesKeepTheirOwn() {
        var animals = DailyRecipe(); animals.setCategory("動物", on: true)
        let plan = DailyPlan.make(day: "2026-11-04", count: 10, recipe: animals, salt: "s")
        let mixed = plan.filter { $0.prompt.hasPrefix("Art style: ") }.count
        XCTAssertTrue((2...8).contains(mixed), "mixed \(mixed)/10")
        var watercolor = DailyRecipe(); watercolor.setCategory("水彩", on: true)
        XCTAssertTrue(DailyPlan.make(day: "2026-11-04", count: 10, recipe: watercolor, salt: "s").allSatisfy { !$0.prompt.hasPrefix("Art style: ") })
        var withIdea = animals; withIdea.idea = "吉卜力風格的貓"
        XCTAssertTrue(DailyPlan.make(day: "2026-11-04", count: 10, recipe: withIdea, salt: "s").allSatisfy { !$0.prompt.hasPrefix("Art style: ") })
    }
}
