import XCTest
@testable import UTUVOWallpaper

final class DailyBatchTests: XCTestCase {
    var paths: AppPaths!
    let day = "2026-11-01"
    let target = CGSize(width: 132, height: 287)

    override func setUp() { paths = makeTempPaths() }
    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func testFullBatchUsesTenDistinctPortraitTemplates() async throws {
        let provider = ScriptedProvider([])
        let service = DailyGenerationService(provider: provider, paths: paths, target: target, recipe: DailyRecipe(styles: PromptTemplate.shared.filter { $0.local == nil }.map(\.id)))
        let results = try await service.run(day: day)
        XCTAssertEqual(results.count, 10)
        XCTAssertEqual(provider.prompts.count, 10)
        XCTAssertEqual(Set(provider.prompts).count, 10)
        XCTAssertTrue(provider.prompts.allSatisfy { $0.contains("9:16") && !$0.contains("16:9") })
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.wallpapers.path)
        XCTAssertEqual(files.count, 10)
        let originals = try FileManager.default.contentsOfDirectory(atPath: paths.originals.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(originals.count, 10)
        XCTAssertTrue(AppPaths.isExcludedFromBackup(paths.originals))
        for name in files {
            XCTAssertEqual(ImageProcessing.pixelSize(at: paths.wallpapers.appendingPathComponent(name)), target)
        }
        // 再跑一次：一天只一批，不再呼叫 provider
        _ = try await service.run(day: day)
        XCTAssertEqual(provider.prompts.count, 10)
        XCTAssertFalse(DailyGenerationService.hasWork(paths: paths, day: day))
    }

    func testAttemptCommittedBeforeRequest() async throws {
        let provider = ScriptedProvider([])
        let root = paths.root, day = day
        var seen: [Int] = []
        provider.onCall = { _ in
            let batch = try? DailyBatch.load(root: root, day: day)
            if let batch { seen.append(batch.attempts[batch.completed.count]) }
        }
        _ = try await DailyGenerationService(provider: provider, paths: paths, target: target, recipe: DailyRecipe(styles: PromptTemplate.shared.filter { $0.local == nil }.map(\.id))).run(day: day, count: 2)
        XCTAssertEqual(seen, [1, 1])
    }

    func test429RetriesWithCooldownThenResumes() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = ScriptedProvider([.ok, .fail(.httpStatus(429)), .ok])
        var service = DailyGenerationService(provider: provider, paths: paths, target: target, recipe: DailyRecipe(styles: PromptTemplate.shared.filter { $0.local == nil }.map(\.id)))
        service.now = { clock.now }

        do { _ = try await service.run(day: day, count: 3); XCTFail("expected 429") }
        catch { XCTAssertEqual(error as? GenerationError, .httpStatus(429)) }
        var batch = try DailyBatch.load(root: paths.root, day: day)
        XCTAssertEqual(batch.completed.count, 1)
        XCTAssertEqual(batch.attempts, [1, 1, 0])
        XCTAssertEqual(batch.retryAfter, clock.now.addingTimeInterval(60))

        // 冷卻中：不送請求
        do { _ = try await service.run(day: day, count: 3); XCTFail("expected cooldown") }
        catch { XCTAssertEqual(error as? GenerationError, .cooldown) }
        XCTAssertEqual(provider.callCount, 2)

        clock.now = clock.now.addingTimeInterval(61)
        let results = try await service.run(day: day, count: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(provider.callCount, 4)
        batch = try DailyBatch.load(root: paths.root, day: day)
        XCTAssertEqual(batch.attempts, [1, 2, 1])
        XCTAssertNil(batch.retryAfter)
    }

    func testRetryLimitIsThreeWith60And300Cooldowns() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = ScriptedProvider([.fail(.httpStatus(503)), .fail(.timeout), .fail(.httpStatus(429)), .ok])
        var service = DailyGenerationService(provider: provider, paths: paths, target: target, recipe: DailyRecipe(styles: PromptTemplate.shared.filter { $0.local == nil }.map(\.id)))
        service.now = { clock.now }
        var cooldowns: [TimeInterval?] = []
        for _ in 0..<3 {
            do { _ = try await service.run(day: day, count: 2); XCTFail() } catch {}
            let batch = try DailyBatch.load(root: paths.root, day: day)
            cooldowns.append(batch.retryAfter.map { $0.timeIntervalSince(clock.now) })
            clock.now = clock.now.addingTimeInterval(400)
        }
        XCTAssertEqual(cooldowns, [60, 300, nil])
        // 用完 3 次：永遠不再送
        do { _ = try await service.run(day: day, count: 2); XCTFail() }
        catch { XCTAssertEqual(error as? GenerationError, .cooldown) }
        XCTAssertEqual(provider.callCount, 3)
        XCTAssertFalse(DailyGenerationService.hasWork(paths: paths, day: day, at: clock.now))
    }

    func test401IsNotRetried() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = ScriptedProvider([.fail(.httpStatus(401))])
        var service = DailyGenerationService(provider: provider, paths: paths, target: target, recipe: DailyRecipe(styles: PromptTemplate.shared.filter { $0.local == nil }.map(\.id)))
        service.now = { clock.now }
        do { _ = try await service.run(day: day, count: 2); XCTFail() }
        catch { XCTAssertEqual(error as? GenerationError, .httpStatus(401)) }
        let batch = try DailyBatch.load(root: paths.root, day: day)
        XCTAssertNil(batch.retryAfter)
        XCTAssertEqual(batch.attempts, [1, 0])
        clock.now = clock.now.addingTimeInterval(86_400)
        do { _ = try await service.run(day: day, count: 2); XCTFail() }
        catch { XCTAssertEqual(error as? GenerationError, .cooldown) }
        XCTAssertEqual(provider.callCount, 1)
    }

    func testRetryableClassification() {
        XCTAssertTrue(DailyBatch.isRetryable(GenerationError.transport))
        XCTAssertTrue(DailyBatch.isRetryable(GenerationError.timeout))
        XCTAssertTrue(DailyBatch.isRetryable(GenerationError.httpStatus(429)))
        XCTAssertTrue(DailyBatch.isRetryable(GenerationError.httpStatus(500)))
        XCTAssertFalse(DailyBatch.isRetryable(GenerationError.httpStatus(401)))
        XCTAssertFalse(DailyBatch.isRetryable(GenerationError.httpStatus(400)))
        XCTAssertFalse(DailyBatch.isRetryable(GenerationError.decoding))
    }
}

final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

final class SceneGenerationTests: XCTestCase {
    var paths: AppPaths!
    let target = CGSize(width: 132, height: 287)
    override func setUp() { paths = makeTempPaths() }
    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func testDayPlusThreeEditsAndPublishOnlyWhenComplete() async throws {
        let failing = ScriptedProvider([.ok, .ok, .fail(.httpStatus(500))])
        let service = SceneGenerationService(provider: failing, paths: paths, target: target)
        do { _ = try await service.generate(prompt: "lake cabin", id: "s1"); XCTFail() } catch {}
        XCTAssertNil(SceneGenerationService.published(paths: paths), "未完成不得發布")

        let provider = ScriptedProvider([])
        let resumed = try await SceneGenerationService(provider: provider, paths: paths, target: target)
            .generate(prompt: "lake cabin", id: "s1")
        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(provider.prompts.count, 0, "白天已存在，不重做")
        XCTAssertEqual(provider.relightPrompts.count, 2, "只補缺的兩個時段")
        XCTAssertEqual(failing.prompts.count, 1)
        XCTAssertEqual(failing.relightPrompts.count, 2)
        XCTAssertEqual(SceneGenerationService.published(paths: paths)?.id, "s1")
        for phase in DayPhase.allCases {
            let url = paths.dynamic.appendingPathComponent("s1/\(phase.rawValue).jpg")
            XCTAssertEqual(ImageProcessing.pixelSize(at: url), target, phase.rawValue)
        }
    }

    func testRelightPromptsKeepComposition() async throws {
        let provider = ScriptedProvider([])
        _ = try await SceneGenerationService(provider: provider, paths: paths, target: target).generate(prompt: "harbor", id: "s2")
        XCTAssertEqual(provider.prompts.count, 1)
        XCTAssertEqual(provider.relightPrompts.count, 3)
        XCTAssertTrue(provider.relightPrompts.allSatisfy {
            $0.contains("Keep the identical framing") && $0.contains("Keep its art style") && $0.contains("9:16") && !$0.contains("cabin")
        })
        XCTAssertTrue(provider.relightPrompts[2].contains("night:"))
        XCTAssertTrue(provider.prompts[0].contains("harbor") && provider.prompts[0].contains("Follow the art style")
                      && !provider.prompts[0].contains("photographic"), "不強迫寫實風景")
    }

    func testEmptyScenePromptRejectedBeforeRequest() async {
        let provider = ScriptedProvider([])
        do { _ = try await SceneGenerationService(provider: provider, paths: paths, target: target).generate(prompt: "  "); XCTFail() }
        catch { XCTAssertEqual(error as? GenerationError, .emptyPrompt) }
        XCTAssertEqual(provider.callCount, 0)
    }
}
