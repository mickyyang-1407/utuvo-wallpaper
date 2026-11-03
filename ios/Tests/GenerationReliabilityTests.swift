import XCTest
@testable import UTUVOWallpaper

final class GenerationReliabilityTests: XCTestCase {
    var paths: AppPaths!
    override func setUp() { paths = makeTempPaths(); paths.prepare(); StubURLProtocol.reset() }
    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func testLoggingProviderRecordsEachRequest() async throws {
        let provider = LoggingImageProvider(base: ScriptedProvider([.ok, .fail(.timeout), .fail(.httpStatus(429))]), paths: paths)
        _ = try await provider.generateImage(prompt: "a")
        do { _ = try await provider.relight(reference: Data(), prompt: "b"); XCTFail() } catch {}
        do { _ = try await provider.generateImage(prompt: "c"); XCTFail() } catch {}
        let entries = GenerationLog.load(paths)
        XCTAssertEqual(entries.map(\.kind), ["generate", "relight", "generate"])
        XCTAssertEqual(entries.map(\.outcome), ["ok", "timeout", "http-429"])
        let summary = try XCTUnwrap(GenerationLog.summary(entries))
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.failures.map(\.outcome), ["http-429", "timeout"])
    }

    func testEmptyPromptIsNotLoggedAndOldEntriesDropOut() async throws {
        let provider = LoggingImageProvider(base: ScriptedProvider([.fail(.emptyPrompt)]), paths: paths)
        do { _ = try await provider.generateImage(prompt: " "); XCTFail() } catch {}
        XCTAssertTrue(GenerationLog.load(paths).isEmpty, "沒送出請求就不算一次")
        let now = Date()
        let old = GenerationLogEntry(at: now.addingTimeInterval(-8 * 86_400), kind: "generate", outcome: "timeout", seconds: 1)
        XCTAssertNil(GenerationLog.summary([old], now: now), "只看最近 7 天")
        for _ in 0..<(GenerationLog.limit + 5) { GenerationLog.append(old, paths: paths) }
        XCTAssertEqual(GenerationLog.load(paths).count, GenerationLog.limit)
    }

    func testTransferSendsBodyFromFileAndReturnsResponse() async throws {
        StubURLProtocol.body = Data("{\"ok\":true}".utf8)
        let transfer = BackgroundTransfer(configuration: StubURLProtocol.configuration())
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
        request.httpMethod = "POST"
        request.httpBody = Data("hello".utf8)
        let (data, response) = try await transfer.send(request)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"ok\":true}")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(StubURLProtocol.capturedBodies.first, Data("hello".utf8))
    }

    /// 背景時間用完被系統中斷：這一批稍後續作，不會整天停在一半。
    func testDailyBatchResumesAfterBackgroundExpiry() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = ScriptedProvider([.ok, .fail(.cancelled), .ok])
        var service = DailyGenerationService(provider: provider, paths: paths, target: CGSize(width: 66, height: 143),
                                             recipe: DailyRecipe(styles: PromptTemplate.shared.filter { $0.local == nil }.map(\.id)))
        service.now = { clock.now }
        do { _ = try await service.run(day: "2026-11-03", count: 3); XCTFail() } catch {}
        XCTAssertTrue(DailyGenerationService.hasWork(paths: paths, day: "2026-11-03", at: clock.now.addingTimeInterval(61)))
        clock.now = clock.now.addingTimeInterval(61)
        let results = try await service.run(day: "2026-11-03", count: 3)
        XCTAssertEqual(results.count, 3)
    }
}

final class DayNightApplyTests: XCTestCase {
    @MainActor
    func testSpecificWallpaperTurnsDayNightOffAndDayNightButtonTurnsItOn() throws {
        let model = AppModel()
        let defaults = model.prefs.defaults
        let saved = (defaults.object(forKey: AppModel.shortcutReadyKey), model.pinnedID, model.dynamicEnabled)
        let savedHistory = model.prefs.servedHistory
        defer {
            model.prefs.servedHistory = savedHistory
            defaults.set(saved.0, forKey: AppModel.shortcutReadyKey)
            model.pinnedID = saved.1; model.prefs.pinnedID = saved.1
            model.dynamicEnabled = saved.2
            model.message = nil
        }
        let item = try XCTUnwrap(model.items.first)
        defaults.set(true, forKey: AppModel.shortcutReadyKey)

        model.dynamicEnabled = true
        XCTAssertEqual(model.applyURL(for: item), ApplyShortcut.runURL)
        XCTAssertFalse(model.dynamicEnabled, "選了特定一張：日夜模式關掉，捷徑才會拿到這張")
        XCTAssertFalse(model.prefs.dynamicEnabled, "捷徑讀的是存起來的設定")
        model.handleShortcutCallback(URL(string: "utuvowallpaper://shortcut/done")!)
        XCTAssertEqual(model.message, L("已換成這張桌布。日夜模式已關閉。"))

        model.message = nil
        XCTAssertEqual(model.applyURL(for: item), ApplyShortcut.runURL)
        model.handleShortcutCallback(URL(string: "utuvowallpaper://shortcut/done")!)
        XCTAssertEqual(model.message, L("已換成這張桌布。"), "本來就沒開：不提日夜模式")

        XCTAssertEqual(model.applyDynamicURL(), ApplyShortcut.runURL)
        XCTAssertTrue(model.prefs.dynamicEnabled)
        model.handleShortcutCallback(URL(string: "utuvowallpaper://shortcut/done")!)
        XCTAssertTrue(model.message?.contains(DayPhase.current(at: Date()).title) == true)

        // 捷徑實際拿到的：日夜開著→日夜那張；套用特定一張後→那一張
        XCTAssertEqual(try CurrentWallpaper.resolve()?.lastPathComponent.contains(DayPhase.current(at: Date()).rawValue), true)
        _ = model.applyURL(for: item)
        XCTAssertEqual(try CurrentWallpaper.resolve(), model.deviceFile(for: item))

        model.message = nil
        model.pinnedID = nil
        model.dynamicEnabled = true
        model.togglePin(item)
        XCTAssertEqual(model.pinnedID, item.id)
        XCTAssertFalse(model.dynamicEnabled, "固定一張也關掉日夜模式，固定才有作用")
    }
}
