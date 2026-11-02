import XCTest
@testable import UTUVOWallpaper

final class OverviewTests: XCTestCase {
    func testSegmentsSplitNewAndOldInCategoryOrder() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-3 * 86_400)
        let url = URL(fileURLWithPath: "/x.jpg")
        let items = [
            WallpaperItem(id: "cosmic-nebula-a.jpg", url: url, isDemo: false, modified: now),
            WallpaperItem(id: "nature-dawn-a.jpg", url: url, isDemo: false, modified: now),
            WallpaperItem(id: "botanical-macro-a.jpg", url: url, isDemo: false, modified: old),
            WallpaperItem(id: "demo:paper-landscape-demo-5k.jpg", url: url, isDemo: true, modified: now),
        ]
        let segs = OverviewFacts.segments(items: items, now: now)
        XCTAssertEqual(segs, [CategorySegment(category: "自然", newCount: 1, oldCount: 1),
                              CategorySegment(category: "極簡", newCount: 0, oldCount: 1),
                              CategorySegment(category: "宇宙", newCount: 1, oldCount: 0)])
        XCTAssertEqual(OverviewFacts.todayNew(items: items, now: now), 2)
    }

    func testNextPhase() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: h))! }
        let fixed = UserDefaults(suiteName: "test.fixed.\(UUID().uuidString)")!  // 不讀 App 的實際設定
        XCTAssertEqual(OverviewFacts.nextPhase(after: at(7), calendar: cal, defaults: fixed).phase, .day)
        XCTAssertEqual(OverviewFacts.nextPhase(after: at(19), calendar: cal, defaults: fixed).time, "21:00")
        XCTAssertEqual(OverviewFacts.nextPhase(after: at(2), calendar: cal, defaults: fixed).phase, .dawn)
    }
}
