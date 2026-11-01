import XCTest
@testable import UTUVOWallpaper

final class PortraitPromptTests: XCTestCase {
    func testAllTemplatesBecomePortrait() {
        XCTAssertEqual(PromptTemplate.shared.count, 10)
        for template in PromptTemplate.shared {
            let out = PortraitPrompt.convert(template.prompt)
            XCTAssertFalse(out.contains("16:9"), template.id)
            XCTAssertTrue(out.contains("9:16"), template.id)
            XCTAssertFalse(out.lowercased().contains("desktop"), template.id)
            XCTAssertTrue(out.contains(PortraitPrompt.clockSentence), template.id)
            XCTAssertFalse(out.contains("wide 9:16"), template.id)
        }
    }

    func testBareRatioAndDesktopWording() {
        let out = PortraitPrompt.convert("Calm sea, wide 16:9 desktop wallpaper composition, no text.")
        XCTAssertTrue(out.hasPrefix("Calm sea, vertical 9:16 iPhone wallpaper composition, no text, "))
        XCTAssertTrue(out.hasSuffix("stays calm."))
        XCTAssertEqual(PortraitPrompt.convert("art, 16:9").contains("9:16"), true)
    }

    func testScenePromptsArePortrait() {
        XCTAssertFalse(DayPhase.basePrompt(scene: "lake").contains("16:9"))
        for phase in DayPhase.allCases { XCTAssertTrue(phase.relightPrompt.contains("9:16")) }
    }
}

final class CropMathTests: XCTestCase {
    func testPortraitNativeToIPhone17ProMax() {
        let rect = CropMath.aspectFillSourceRect(source: CGSize(width: 2160, height: 3840), target: CGSize(width: 1320, height: 2868))
        XCTAssertEqual(rect.height, 3840)
        XCTAssertEqual(rect.width, 1767)   // 3840 × 1320 / 2868 = 1767.4
        XCTAssertEqual(rect.minX, 196)     // (2160 − 1767) / 2 置中
        XCTAssertEqual(rect.minY, 0)
    }

    func testLandscapeDemoCropsCentered() {
        let rect = CropMath.aspectFillSourceRect(source: CGSize(width: 5120, height: 2880), target: CGSize(width: 1206, height: 2622))
        XCTAssertEqual(rect.height, 2880)
        XCTAssertEqual(rect.width, 1325)
        XCTAssertEqual(rect.midX, 2560, accuracy: 1)
    }

    func testTallerSourceCropsTopAndBottom() {
        let rect = CropMath.aspectFillSourceRect(source: CGSize(width: 1000, height: 3000), target: CGSize(width: 1000, height: 2000))
        XCTAssertEqual(rect, CGRect(x: 0, y: 500, width: 1000, height: 2000))
    }

    func testPortraitPixelsNormalisesOrientation() {
        XCTAssertEqual(CropMath.portraitPixels(CGSize(width: 2868, height: 1320)), CGSize(width: 1320, height: 2868))
    }

    func testCropProducesExactTargetJPEG() throws {
        let png = TestImage.png(size: CGSize(width: 216, height: 384))
        let jpeg = try ImageProcessing.cropToJPEG(imageData: png, target: CGSize(width: 132, height: 287))
        XCTAssertEqual(ImageProcessing.pixelSize(of: jpeg), CGSize(width: 132, height: 287))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
    }
}

final class DayPhaseTests: XCTestCase {
    func testBoundaries() {
        let expected: [(Int, DayPhase)] = [(0, .night), (5, .night), (6, .dawn), (8, .dawn), (9, .day),
                                           (17, .day), (18, .dusk), (20, .dusk), (21, .night), (23, .night)]
        for (hour, phase) in expected { XCTAssertEqual(DayPhase.current(hour: hour), phase, "hour \(hour)") }
    }

    func testDateBoundaryMinutes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let d1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 5, minute: 59, second: 59))!
        let d2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 6, minute: 0))!
        XCTAssertEqual(DayPhase.current(at: d1, calendar: cal), .night)
        XCTAssertEqual(DayPhase.current(at: d2, calendar: cal), .dawn)
    }
}

final class RotationTests: XCTestCase {
    private func slot(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Int { WallpaperSelection.hourSlot(year: y, month: m, day: d, hour: h)! }

    /// 依序呼叫「取得目前桌布」，回傳每次的索引。
    private func serve(_ slots: [Int], count: Int, start: RotationState = RotationState()) -> [Int] {
        var state = start
        return slots.map { s in
            let r = WallpaperSelection.step(state, slot: s, count: count, force: false)
            state = r.state
            return r.index!
        }
    }

    func testSameHourTwiceReturnsSameIndex() {
        let s = slot(2026, 11, 1, 7)
        XCTAssertEqual(serve([s, s], count: 5), [0, 0])
        let warm = RotationState(cursor: 3, lastServedSlot: s - 1)
        XCTAssertEqual(serve([s, s, s], count: 5, start: warm), [4, 4, 4])
    }

    func testNextHourAdvances() {
        XCTAssertEqual(serve([slot(2026, 11, 1, 7), slot(2026, 11, 1, 8), slot(2026, 11, 1, 9)], count: 5), [0, 1, 2])
    }

    func testSameTimeDailyForThreeDaysAdvancesEachDay() {
        for count in [2, 3, 4, 6, 8, 12, 24, 10] {
            let got = serve([slot(2026, 11, 1, 7), slot(2026, 11, 2, 7), slot(2026, 11, 3, 7), slot(2026, 11, 4, 7)], count: count)
            XCTAssertEqual(got, [0, 1, 2, 3].map { $0 % count }, "count \(count)")
        }
    }

    func testMidnightAdvances() {
        let a = slot(2026, 11, 1, 23), b = slot(2026, 11, 2, 0)
        XCTAssertEqual(b, a + 1)
        XCTAssertEqual(serve([a, b], count: 4), [0, 1])
    }

    func testMonthAndYearEdgesAreContinuous() {
        XCTAssertEqual(slot(2026, 12, 1, 0), slot(2026, 11, 30, 23) + 1)
        XCTAssertEqual(slot(2027, 1, 1, 0), slot(2026, 12, 31, 23) + 1)
        XCTAssertEqual(slot(2028, 3, 1, 0), slot(2028, 2, 29, 23) + 1)
        XCTAssertEqual(serve([slot(2026, 11, 30, 7), slot(2026, 12, 1, 7)], count: 3), [0, 1])
    }

    func testReproducibleFromSameState() {
        let state = RotationState(cursor: 7, lastServedSlot: 100)
        let a = WallpaperSelection.step(state, slot: 101, count: 5, force: false)
        let b = WallpaperSelection.step(state, slot: 101, count: 5, force: false)
        XCTAssertEqual(a.state, b.state)
        XCTAssertEqual(a.index, b.index)
        XCTAssertEqual(a.index, 3)
    }

    func testForceAdvancesWithinSameHourAndThenHolds() {
        let s = slot(2026, 11, 1, 7)
        var state = RotationState(cursor: 0, lastServedSlot: s)
        let next = WallpaperSelection.step(state, slot: s, count: 5, force: true)
        XCTAssertEqual(next.index, 1)
        state = next.state
        XCTAssertEqual(WallpaperSelection.step(state, slot: s, count: 5, force: false).index, 1, "同一小時再取，不再前進")
    }

    func testCountChangeStaysInBounds() {
        let state = RotationState(cursor: 41, lastServedSlot: 10)
        for count in 1...12 {
            let r = WallpaperSelection.step(state, slot: 11, count: count, force: false)
            XCTAssertTrue((0..<count).contains(r.index!), "count \(count)")
        }
        XCTAssertNil(WallpaperSelection.step(state, slot: 11, count: 0, force: false).index)
        XCTAssertTrue((0..<3).contains(WallpaperSelection.step(RotationState(cursor: -5), slot: 1, count: 3, force: false).index!))
    }

    func testChoosePriorityAndStateOnlyMovesForRotation() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let night = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 22))!
        let ids = ["a", "b", "c", "d"]
        let phases: [DayPhase: String] = [.dawn: "p-dawn", .day: "p-day", .dusk: "p-dusk", .night: "p-night"]
        let state = RotationState(cursor: 5, lastServedSlot: 1)
        let dyn = WallpaperSelection.choose(at: night, dynamicPhaseIDs: phases, pinnedID: "b", available: ids,
                                            favorites: [], favoritesOnly: false, state: state, calendar: cal)
        XCTAssertEqual(dyn.choice, .init(id: "p-night", source: .dynamic(.night)))
        XCTAssertEqual(dyn.state, state)
        let pinned = WallpaperSelection.choose(at: night, dynamicPhaseIDs: nil, pinnedID: "b", available: ids,
                                               favorites: [], favoritesOnly: false, state: state, calendar: cal)
        XCTAssertEqual(pinned.choice?.source, .pinned)
        XCTAssertEqual(pinned.state, state)
        let rotated = WallpaperSelection.choose(at: night, dynamicPhaseIDs: nil, pinnedID: "gone", available: ids,
                                                favorites: [], favoritesOnly: false, state: state, calendar: cal)
        XCTAssertEqual(rotated.choice, .init(id: "c", source: .rotation(2)))   // cursor 6 % 4
        XCTAssertEqual(rotated.state.cursor, 6)
        for hour in 0..<24 {
            let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: hour))!
            let pick = WallpaperSelection.choose(at: date, dynamicPhaseIDs: nil, pinnedID: nil, available: ids,
                                                 favorites: ["c", "a"], favoritesOnly: true, state: RotationState(cursor: hour), calendar: cal)
            XCTAssertTrue(["a", "c"].contains(pick.choice!.id))
        }
        XCTAssertNotNil(WallpaperSelection.choose(at: night, dynamicPhaseIDs: nil, pinnedID: nil, available: ids,
                                                  favorites: [], favoritesOnly: true, state: state, calendar: cal).choice)
        XCTAssertNil(WallpaperSelection.choose(at: night, dynamicPhaseIDs: nil, pinnedID: nil, available: [],
                                               favorites: [], favoritesOnly: false, state: state, calendar: cal).choice)
    }
}

final class CategoryTests: XCTestCase {
    func testTemplatePrefixes() {
        XCTAssertEqual(WallpaperCategory.category(forFileName: "nature-dawn-daily-2026-11-01.jpg"), "自然")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "botanical-macro-abc.jpg"), "自然")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "minimal-paper-x.jpg"), "極簡")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "abstract-flow-x.jpg"), "抽象")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "gradient-tide-x.jpg"), "抽象")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "illustration-dusk-x.jpg"), "插畫")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "cosmic-nebula-x.jpg"), "宇宙")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "watercolor-meadow-x.jpg"), "水彩")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "ARCHITECTURE-ARCADE-x.jpg"), "建築")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "animation-coast-x.jpg"), "動畫")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "paper-landscape-demo-5k.jpg"), "極簡")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "nature-dawnish.jpg"), "其他")
        XCTAssertEqual(WallpaperCategory.category(forFileName: "random.jpg"), "其他")
    }

    func testFilterOrderMatchesSpec() {
        XCTAssertEqual(GalleryFilter.allFilters.map(\.id),
                       ["all", "favorites", "c-自然", "c-極簡", "c-抽象", "c-插畫", "c-宇宙", "c-水彩", "c-建築", "c-動畫", "c-其他"])
    }
}
