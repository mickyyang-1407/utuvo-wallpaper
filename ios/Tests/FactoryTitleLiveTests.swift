import XCTest
@testable import UTUVOWallpaper

final class ProviderFactoryTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var store: KeychainCredentialStore!

    override func setUp() {
        suite = "utuvo-factory-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        store = KeychainCredentialStore(service: "com.utuvo.wallpaper.tests." + UUID().uuidString)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? store.delete()
    }

    func testFakeFlagGivesFakeProviderForForegroundAndBackground() throws {
        defaults.set(true, forKey: "UTUVOFakeProvider")
        XCTAssertTrue(ProviderFactory.usesFakeProvider(defaults))
        // 有 key 也一樣走假 provider，不會連網
        let provider = try ProviderFactory.make(store: store, defaults: defaults, environment: ["OPENAI_API_KEY": "sk-test-fake"])
        XCTAssertTrue(provider is FakeImageProvider)
    }

    func testWithoutFlagNeedsCredential() throws {
        XCTAssertFalse(ProviderFactory.usesFakeProvider(defaults))
        XCTAssertThrowsError(try ProviderFactory.make(store: store, defaults: defaults, environment: [:])) {
            XCTAssertEqual($0 as? GenerationError, .missingCredential)
        }
        let provider = try ProviderFactory.make(store: store, defaults: defaults, environment: ["OPENAI_API_KEY": "sk-test-fake"])
        XCTAssertTrue(provider is OpenAIImageProvider)   // 只建立，不送請求
    }

    func testBackgroundDailyRunUsesFactoryProvider() async throws {
        defaults.set(true, forKey: "UTUVOFakeProvider")
        let paths = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let service = DailyGenerationService(provider: try ProviderFactory.make(store: store, defaults: defaults, environment: [:]),
                                             paths: paths, target: CGSize(width: 66, height: 143))
        let results = try await service.run(day: "2026-11-01", count: 2)
        XCTAssertEqual(results.count, 2)
    }
}

final class TitleTests: XCTestCase {
    private func item(_ name: String, demo: Bool = false, modified: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> WallpaperItem {
        WallpaperItem(id: demo ? "demo:" + name : name, url: URL(fileURLWithPath: "/" + name), isDemo: demo, modified: modified)
    }

    func testTemplateTitleWithDateAndDuplicates() {
        let zh = WallpaperTitles.dayFormatter(language: "zh-Hant")
        let items = [item("abstract-flow-daily-2026-11-01.jpg"),
                     item("abstract-flow-aaaa.jpg", modified: DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 1, hour: 12).date!),
                     item("gradient-tide-daily-2026-10-31.jpg"),
                     item("paper-landscape-demo-5k.jpg", demo: true),
                     item("paper-landscape-other.jpg"),
                     item("random-name.jpg")]
        let titles = WallpaperTitles.titles(for: items, formatter: zh)
        // 標題跟系統語言走：用同一張表查，避免測試依賴模擬器語言
        let flow = WallpaperTitles.templateTitle("abstract-flow")!, tide = WallpaperTitles.templateTitle("gradient-tide")!
        XCTAssertTrue(["流動光帶", "Flowing Ribbons"].contains(flow))
        XCTAssertEqual(titles["abstract-flow-aaaa.jpg"], "\(flow) · 11/1 · 1")
        XCTAssertEqual(titles["abstract-flow-daily-2026-11-01.jpg"], "\(flow) · 11/1 · 2")
        XCTAssertEqual(titles["gradient-tide-daily-2026-10-31.jpg"], "\(tide) · 10/31")
        XCTAssertEqual(titles["demo:paper-landscape-demo-5k.jpg"], WallpaperTitles.legacyTitle("paper-landscape-demo-5k.jpg"))
        XCTAssertEqual(titles["paper-landscape-other.jpg"], "paper-landscape-other", "舊固定名只給完全相同的檔名")
        XCTAssertEqual(titles["random-name.jpg"], "random-name")
        XCTAssertFalse(titles.values.contains { $0.contains("抽象 ·") || $0.contains("Abstract ·") }, "不帶分類前綴")
    }

    func testEnglishDateFormat() {
        let en = WallpaperTitles.dayFormatter(language: "en")
        XCTAssertEqual(WallpaperTitles.baseTitle(item("nature-dawn-daily-2026-11-01.jpg"), formatter: en).hasSuffix(" · Nov 1"), true)
    }
}

@MainActor
final class LiveOneCheckTests: XCTestCase {
    func testDoesNotStartWithoutArgument() {
        let suite = "utuvo-live-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(LiveOneCheck.isRequested(defaults))
        let model = AppModel()
        XCTAssertFalse(model.startLiveOneIfRequested(defaults: defaults))
        XCTAssertNil(model.liveStatus)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: LiveOneCheck.argument), "測試程序本身沒有帶這個參數")
    }

    func testLiveDayDoesNotCollideWithDailyBatch() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(LiveOneCheck.day(date), "live-check-" + AppPaths.dayString(date))
        XCTAssertNotEqual(DailyBatch.url(root: URL(fileURLWithPath: "/r"), day: LiveOneCheck.day(date)),
                          DailyBatch.url(root: URL(fileURLWithPath: "/r"), day: AppPaths.dayString(date)))
    }
}
