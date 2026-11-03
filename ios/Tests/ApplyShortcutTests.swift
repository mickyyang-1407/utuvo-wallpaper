import XCTest
@testable import UTUVOWallpaper

final class ApplyShortcutTests: XCTestCase {
    func testRunURLNamesShortcutAndCallsBack() throws {
        let c = try XCTUnwrap(URLComponents(url: ApplyShortcut.runURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.scheme, "shortcuts")
        XCTAssertEqual(c.host, "x-callback-url")
        XCTAssertEqual(c.path, "/run-shortcut")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["name"], "UTUVO Set Wallpaper")
        XCTAssertEqual(q["x-success"], "utuvowallpaper://shortcut/done")
        XCTAssertEqual(q["x-error"], "utuvowallpaper://shortcut/error")
        XCTAssertEqual(q["x-cancel"], "utuvowallpaper://shortcut/cancel")
    }

    func testCallbackParsing() {
        XCTAssertEqual(ApplyShortcut.outcome(of: URL(string: "utuvowallpaper://shortcut/done")!), .done)
        XCTAssertEqual(ApplyShortcut.outcome(of: URL(string: "utuvowallpaper://shortcut/cancel")!), .cancelled)
        XCTAssertEqual(ApplyShortcut.outcome(of: URL(string: "utuvowallpaper://shortcut/error?errorMessage=Not%20found")!), .failed("Not found"))
        XCTAssertEqual(ApplyShortcut.outcome(of: URL(string: "utuvowallpaper://shortcut/error")!), .failed(nil))
        XCTAssertNil(ApplyShortcut.outcome(of: URL(string: "utuvowallpaper://other/done")!))
        XCTAssertNil(ApplyShortcut.outcome(of: URL(string: "https://shortcut/done")!))
    }

    func testBundledShortcutIsSignedAndNamed() throws {
        let url = try XCTUnwrap(ApplyShortcut.bundledFile, "App 內要附捷徑檔")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, ApplyShortcut.name)
        let head = try Data(contentsOf: url).prefix(4)
        XCTAssertEqual(String(decoding: head, as: UTF8.self), "AEA1", "要是簽署過的捷徑（AEA 格式），否則 iOS 不讓加入")
    }

    @MainActor
    func testFirstApplyShowsSetupThenRunsAfterSuccess() throws {
        let model = AppModel()
        let defaults = model.prefs.defaults
        let savedReady = defaults.object(forKey: AppModel.shortcutReadyKey)
        let savedPinnedID = model.pinnedID
        defer {
            model.pinnedID = savedPinnedID; model.prefs.pinnedID = savedPinnedID
            defaults.set(savedReady, forKey: AppModel.shortcutReadyKey)
        }
        let item = try XCTUnwrap(model.items.first, "至少有示範圖")
        defaults.set(false, forKey: AppModel.shortcutReadyKey)

        XCTAssertNil(model.applyURL(for: item), "沒成功跑過：不直接跳捷徑")
        XCTAssertEqual(model.shortcutSetup, .firstTime)
        XCTAssertEqual(model.pinnedID, item.id, "按了就先固定這張")

        XCTAssertTrue(model.handleShortcutCallback(URL(string: "utuvowallpaper://shortcut/done")!))
        XCTAssertNil(model.shortcutSetup)
        XCTAssertEqual(model.applyURL(for: item), ApplyShortcut.runURL, "成功過一次：之後直接跑捷徑")

        XCTAssertTrue(model.handleShortcutCallback(URL(string: "utuvowallpaper://shortcut/error?errorMessage=x")!))
        XCTAssertEqual(model.shortcutSetup, .failed("x"))
        XCTAssertNil(model.applyURL(for: item), "失敗後回到設定說明")
        model.shortcutSetup = nil
        XCTAssertFalse(model.handleShortcutCallback(URL(string: "utuvowallpaper://elsewhere")!))
    }
}
