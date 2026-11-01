import XCTest
@testable import UTUVOWallpaper

/// 用 URLProtocol 樁攔截：OpenAI provider 的請求從未離開這台機器。
final class OpenAIProviderTests: XCTestCase {
    let fakeKey = ["fixture", "not", "a", "real", "key", "1234567890"].joined(separator: "-")

    override func setUp() { StubURLProtocol.reset() }

    private func provider() -> OpenAIImageProvider {
        OpenAIImageProvider(apiKey: fakeKey, configuration: StubURLProtocol.configuration())
    }

    func testGenerationRequestShape() async throws {
        StubURLProtocol.body = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": TestImage.png(size: CGSize(width: 4, height: 4)).base64EncodedString()]]])
        let png = try await provider().generateImage(prompt: "a lake")
        XCTAssertNotNil(ImageProcessing.pixelSize(of: png))
        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/images/generations")
        let body = try JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies[0]) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "gpt-image-2")
        XCTAssertEqual(body["size"] as? String, "2160x3840")
        XCTAssertEqual(body["quality"] as? String, "high")
        XCTAssertEqual(body["n"] as? Int, 1)
    }

    func testEditRequestIsMultipartWithImageArray() async throws {
        StubURLProtocol.body = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": TestImage.png(size: CGSize(width: 4, height: 4)).base64EncodedString()]]])
        _ = try await provider().relight(reference: TestImage.png(size: CGSize(width: 4, height: 4)), prompt: "night")
        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/images/edits")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let text = String(decoding: StubURLProtocol.capturedBodies[0], as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"image[]\""))
        XCTAssertTrue(text.contains("gpt-image-2"))
        XCTAssertTrue(text.contains("2160x3840"))
    }

    func testErrorsNeverContainKeyBodyOrHeaders() async {
        for status in [400, 401, 403, 429, 500, 503, 418] {
            StubURLProtocol.reset()
            StubURLProtocol.status = status
            StubURLProtocol.body = Data("{\"error\":{\"message\":\"Incorrect API key provided: \(fakeKey)\"}}".utf8)
            do {
                _ = try await provider().generateImage(prompt: "x")
                XCTFail("expected failure")
            } catch {
                XCTAssertEqual(error as? GenerationError, .httpStatus(status))
                let text = [error.localizedDescription, String(describing: error), "\(error)"].joined(separator: " ")
                XCTAssertFalse(text.contains(fakeKey), "status \(status)")
                XCTAssertFalse(text.contains("Incorrect API key"), "status \(status)")
                XCTAssertFalse(text.contains("req_secret_header"), "status \(status)")
                XCTAssertFalse(text.contains("sk-"), "status \(status)")
            }
        }
    }

    func testAllErrorDescriptionsAreKeyFree() {
        let errors: [GenerationError] = [.emptyPrompt, .missingCredential, .invalidResponse, .httpStatus(401),
                                         .httpStatus(429), .httpStatus(502), .timeout, .transport, .decoding,
                                         .writeFailed, .cancelled, .cooldown]
        for e in errors {
            let text = e.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("sk-"))
        }
    }

    func testInvalidJSONIsInvalidResponse() async {
        StubURLProtocol.body = Data("not json \(fakeKey)".utf8)
        do { _ = try await provider().generateImage(prompt: "x"); XCTFail() }
        catch {
            XCTAssertEqual(error as? GenerationError, .invalidResponse)
            XCTAssertFalse(error.localizedDescription.contains(fakeKey))
        }
    }
}

final class KeychainTests: XCTestCase {
    var store: KeychainCredentialStore!

    override func setUp() { store = KeychainCredentialStore(service: "com.utuvo.wallpaper.tests." + UUID().uuidString) }
    override func tearDown() {
        try? store.delete()
        XCTAssertEqual(try? store.exists(), false, "一次性 service 必須清除")
    }

    func testSaveReadReplaceDelete() throws {
        XCTAssertNotEqual(store.service, KeychainCredentialStore.defaultService)
        XCTAssertFalse(try store.exists())
        XCTAssertNil(try store.read())
        try store.save("  sk-test-one  ")
        XCTAssertTrue(try store.exists())
        XCTAssertEqual(try store.read(), "sk-test-one")
        try store.save("sk-test-two")
        XCTAssertEqual(try store.read(), "sk-test-two")
        try store.delete()
        XCTAssertFalse(try store.exists())
        XCTAssertNil(try store.read())
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try store.save("   "))
        XCTAssertThrowsError(try store.save("sk test"))
        XCTAssertThrowsError(try store.save("金鑰"))
        XCTAssertFalse((try? store.exists()) ?? true)
    }

    func testResolverOrderKeychainThenEnvironment() throws {
        XCTAssertNil(CredentialResolver.resolve(store: store, environment: [:]))
        XCTAssertEqual(CredentialResolver.resolve(store: store, environment: ["OPENAI_API_KEY": "sk-env"])?.source, .environment)
        try store.save("sk-chain")
        let resolved = CredentialResolver.resolve(store: store, environment: ["OPENAI_API_KEY": "sk-env"])
        XCTAssertEqual(resolved?.key, "sk-chain")
        XCTAssertEqual(resolved?.source, .keychain)
    }
}

final class CurrentWallpaperTests: XCTestCase {
    var paths: AppPaths!
    var defaults: UserDefaults!
    var suite: String!

    override func setUp() {
        paths = makeTempPaths()
        paths.prepare()
        suite = "utuvo-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.root)
        defaults.removePersistentDomain(forName: suite)
    }

    func testResolvesDemoWhenEmptyAndCropsToDevice() throws {
        let prefs = Preferences(defaults: defaults)
        let target = CGSize(width: 132, height: 287)
        let url = try XCTUnwrap(try CurrentWallpaper.resolve(paths: paths, prefs: prefs, bundle: .main, target: target))
        XCTAssertEqual(ImageProcessing.pixelSize(at: url), target)
    }

    func testPinnedAndDynamic() throws {
        let prefs = Preferences(defaults: defaults)
        let target = CGSize(width: 132, height: 287)
        for name in ["nature-dawn-a.jpg", "cosmic-nebula-b.jpg"] {
            try ImageProcessing.write(try ImageProcessing.cropToJPEG(imageData: TestImage.png(size: CGSize(width: 216, height: 384)), target: target),
                                      to: paths.wallpapers.appendingPathComponent(name))
        }
        prefs.pinnedID = "cosmic-nebula-b.jpg"
        XCTAssertEqual(try CurrentWallpaper.resolve(paths: paths, prefs: prefs, target: target)?.lastPathComponent, "cosmic-nebula-b.jpg")
        prefs.dynamicEnabled = true
        let dynamicURL = try XCTUnwrap(try CurrentWallpaper.resolve(paths: paths, prefs: prefs, target: target))
        XCTAssertTrue(dynamicURL.lastPathComponent.hasPrefix("hours-"))
        prefs.dynamicEnabled = false
        let before = prefs.rotation.cursor
        _ = try CurrentWallpaper.advance(paths: paths, prefs: prefs, target: target)
        XCTAssertNil(prefs.pinnedID)
        XCTAssertEqual(prefs.rotation.cursor, before + 1)
    }

    func testGetCurrentHoldsWithinHourAndAdvancesNextHour() throws {
        let prefs = Preferences(defaults: defaults)
        let target = CGSize(width: 132, height: 287)
        for name in ["nature-dawn-a.jpg", "cosmic-nebula-b.jpg", "gradient-tide-c.jpg"] {
            try ImageProcessing.write(try ImageProcessing.cropToJPEG(imageData: TestImage.png(size: CGSize(width: 216, height: 384)), target: target),
                                      to: paths.wallpapers.appendingPathComponent(name))
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }
        let first = try CurrentWallpaper.resolve(at: at(1, 23), paths: paths, prefs: prefs, target: target, calendar: cal)
        let again = try CurrentWallpaper.resolve(at: at(1, 23, 40), paths: paths, prefs: prefs, target: target, calendar: cal)
        let midnight = try CurrentWallpaper.resolve(at: at(2, 0), paths: paths, prefs: prefs, target: target, calendar: cal)
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, midnight)
        XCTAssertEqual(prefs.rotation.cursor, 1)
    }
}
