import Foundation
import AppKit

/// 工單 0003 的自測：標籤、解析度級距、多選、刪除計畫、真的移到垃圾桶。
/// 全部在隔離資料夾裡跑，不碰真資料、不改桌面。
extension SelfTest {
    static func runLibraryTests(tempRoot: URL, defaults: UserDefaults,
                                record: (String, Bool, String) -> Void) async {
        let fm = FileManager.default

        // MARK: TagStore
        let tagRoot = tempRoot.appendingPathComponent("tag-fixture", isDirectory: true)
        do {
            try fm.createDirectory(at: tagRoot, withIntermediateDirectories: true)
            let store = TagStore(root: tagRoot)
            let startsEmpty = store.tags.isEmpty
            try store.addTag(name: "  旅行 ", color: "#30D158")
            try store.addTag(name: "工作", color: "#0A84FF")
            var duplicateRejected = false
            do { try store.addTag(name: "旅行", color: "#FF375F") } catch let error as TagStore.TagError { duplicateRejected = error == .duplicateName }
            var emptyRejected = false
            do { try store.addTag(name: "   ", color: "#FF375F") } catch let error as TagStore.TagError { emptyRejected = error == .emptyName }
            record("標籤：新增（去頭尾空白）、拒絕同名與空白名稱",
                   startsEmpty && store.tags.map(\.name) == ["旅行", "工作"] && duplicateRejected && emptyRejected,
                   "標籤 = \(store.tags.map(\.name))")

            try store.set("旅行", assigned: true, for: ["a.jpg"])
            let single = store.ids(with: "旅行") == ["a.jpg"]
            try store.set("旅行", assigned: true, for: ["a.jpg", "b.jpg", "c.jpg"])
            let multi = store.ids(with: "旅行") == ["a.jpg", "b.jpg", "c.jpg"] && store.allHave("旅行", ids: ["a.jpg", "b.jpg"])
            try store.set("旅行", assigned: false, for: ["b.jpg"])
            let partial = !store.allHave("旅行", ids: ["a.jpg", "b.jpg"]) && store.count(for: "旅行", among: ["a.jpg", "b.jpg", "c.jpg"]) == 2
            record("標籤：單張指派、多張一次指派、多張移除", single && multi && partial,
                   "旅行 = \(store.ids(with: "旅行").sorted())")

            try store.set("工作", assigned: true, for: ["a.jpg"])
            try store.renameTag("旅行", to: "出遊")
            let renamed = store.tag(named: "旅行") == nil && store.ids(with: "出遊") == ["a.jpg", "c.jpg"]
            try store.recolorTag("出遊", color: "#FF9F0A")
            let recolored = store.tag(named: "出遊")?.color == "#FF9F0A"
            let reloaded = TagStore(root: tagRoot)
            let persisted = reloaded.document == store.document
            record("標籤：改名帶走指派、改顏色、重新讀檔內容一致", renamed && recolored && persisted,
                   "a.jpg 標籤 = \(store.tags(for: "a.jpg").map(\.name))")

            try store.deleteTag("工作")
            let deletedTag = store.tag(named: "工作") == nil && store.tags(for: "a.jpg").map(\.name) == ["出遊"]
            record("標籤：刪標籤只刪標籤與指派", deletedTag, "剩下標籤 = \(store.tags.map(\.name))")

            try store.removeAssignments(for: ["a.jpg"])
            let removedAssignment = store.tags(for: "a.jpg").isEmpty && store.ids(with: "出遊") == ["c.jpg"]
                && store.tag(named: "出遊") != nil
            record("標籤：圖被刪除時移除其指派（標籤保留）", removedAssignment, "出遊 = \(store.ids(with: "出遊").sorted())")

            // 壞檔救援
            let corrupt = Data("{not json".utf8)
            try corrupt.write(to: store.url)
            let rescued = TagStore(root: tagRoot)
            let corruptURL = rescued.recoveredCorruptURL
            let corruptKept = corruptURL.map { (try? Data(contentsOf: $0)) == corrupt } ?? false
            let named = corruptURL?.lastPathComponent.hasPrefix("tags.corrupt-") == true
            try rescued.addTag(name: "新", color: "#0A84FF")
            let corruptStill = corruptURL.map { (try? Data(contentsOf: $0)) == corrupt } ?? false
            record("標籤：壞檔改名保留、從空集合開始、之後寫入不覆蓋壞檔",
                   rescued.tags.map(\.name) == ["新"] && corruptKept && named && corruptStill,
                   corruptURL?.lastPathComponent ?? "沒有改名")

            // 救援失敗（資料夾不可寫，壞檔改不了名）→ 唯讀、拒絕寫入、壞檔原封不動。
            let lockedRoot = tempRoot.appendingPathComponent("tag-locked", isDirectory: true)
            try fm.createDirectory(at: lockedRoot, withIntermediateDirectories: true)
            let lockedFile = lockedRoot.appendingPathComponent("tags.json")
            try corrupt.write(to: lockedFile)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedRoot.path)
            let locked = TagStore(root: lockedRoot)
            var refused = false
            do { try locked.addTag(name: "會覆蓋嗎", color: "#0A84FF") } catch let error as TagStore.TagError { refused = error == .readOnly }
            let lockedUntouched = (try? Data(contentsOf: lockedFile)) == corrupt
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedRoot.path)
            record("標籤：壞檔救援失敗 → 唯讀、拒絕寫入、壞檔不被覆蓋",
                   locked.isReadOnly && refused && lockedUntouched && locked.recoveredCorruptURL == nil,
                   "唯讀 = \(locked.isReadOnly)、拒絕 = \(refused)")

            // 載入後檔案才被弄壞：寫入前會再檢查，不覆蓋。
            let lateRoot = tempRoot.appendingPathComponent("tag-late", isDirectory: true)
            try fm.createDirectory(at: lateRoot, withIntermediateDirectories: true)
            let late = TagStore(root: lateRoot)
            try late.addTag(name: "一", color: "#0A84FF")
            try corrupt.write(to: late.url)
            var lateRefused = false
            do { try late.addTag(name: "二", color: "#0A84FF") } catch let error as TagStore.TagError { lateRefused = error == .readOnly }
            record("標籤：寫入前發現磁碟上的檔已壞 → 拒絕寫入、不覆蓋",
                   lateRefused && (try? Data(contentsOf: late.url)) == corrupt, "拒絕 = \(lateRefused)")

            let leftovers = (try? fm.contentsOfDirectory(atPath: tagRoot.path))?.filter { $0.hasSuffix(".tmp") } ?? []
            record("標籤：原子寫入不留暫存檔", leftovers.isEmpty, "暫存檔 \(leftovers.count) 個")
        } catch {
            record("標籤：流程", false, "未預期錯誤 \(error)")
        }

        // MARK: 解析度級距
        let tiers = [6144, 6143, 5120, 5119, 3840, 3839, 1920].map(ResolutionTier.tier(forWidth:))
        let tiersOK = tiers == [.sixK, .fiveK, .fiveK, .fourK, .fourK, .other, .other]
        let histogram = ResolutionTier.histogram(widths: [6144, 6144, 3840, 1024])
        let histogramOK = histogram.map(\.0) == [.sixK, .fourK, .other] && histogram.map(\.1) == [2, 1, 1]
        record("解析度：6K ≥ 6144、5K ≥ 5120、4K ≥ 3840、其他；只列有圖的級距",
               tiersOK && histogramOK, "直方圖 = \(histogram.map { "\($0.0.rawValue):\($0.1)" })")

        // MARK: 多選
        let order = ["a", "b", "c", "d", "e"]
        var state = SelectionLogic.click(SelectionState(), id: "b", modifiers: [], order: order)
        let plain = state == SelectionState(ids: ["b"], anchor: "b", primary: "b")
        state = SelectionLogic.click(state, id: "d", modifiers: .command, order: order)
        let cmdAdd = state.ids == ["b", "d"] && state.primary == "d" && state.anchor == "d"
        state = SelectionLogic.click(state, id: "d", modifiers: .command, order: order)
        let cmdRemove = state.ids == ["b"] && state.primary == "b"
        record("多選：點一下單選、⌘ 加入與移出", plain && cmdAdd && cmdRemove, "選取 = \(state.ids.sorted())")

        state = SelectionLogic.click(SelectionState(), id: "b", modifiers: [], order: order)
        state = SelectionLogic.click(state, id: "e", modifiers: .shift, order: order)
        let shiftForward = state.ids == ["b", "c", "d", "e"] && state.anchor == "b" && state.primary == "e"
        state = SelectionLogic.click(state, id: "a", modifiers: .shift, order: order)
        let shiftBack = state.ids == ["a", "b", "c", "d", "e"] && state.anchor == "b"
        let noAnchor = SelectionLogic.click(SelectionState(), id: "c", modifiers: .shift, order: order).ids == ["c"]
        record("多選：Shift 依畫面順序整段加入（前後都可、沒錨點時當單選）", shiftForward && shiftBack && noAnchor,
               "選取 = \(state.ids.sorted())")

        state = SelectionState(ids: ["b", "c"], anchor: "c", primary: "c")
        state = SelectionLogic.click(state, id: "c", modifiers: .option, order: order)
        let optionRemove = state.ids == ["b"] && state.primary == "b" && state.anchor == "b"
        let optionLast = SelectionLogic.click(state, id: "b", modifiers: .option, order: order) == SelectionState()
        let optionOther = SelectionLogic.click(state, id: "e", modifiers: .option, order: order).ids == ["b"]
        record("多選：⌥ 移出那張；唯一一張時全部清空；沒選的不受影響", optionRemove && optionLast && optionOther,
               "選取 = \(state.ids.sorted())")

        let all = SelectionLogic.selectAll(SelectionState(ids: ["c"], anchor: "c", primary: "c"), order: order)
        let cleared = SelectionLogic.clear()
        let afterDelete = SelectionLogic.afterRemoval(removed: ["b", "c"], previousOrder: order, survivingOrder: ["a", "d", "e"])
        let afterDeleteTail = SelectionLogic.afterRemoval(removed: ["d", "e"], previousOrder: order, survivingOrder: ["a", "b", "c"])
        record("多選：⌘A 全選保留主要選取、Esc 清空、刪除後選附近下一張",
               all.ids == Set(order) && all.primary == "c" && cleared.ids.isEmpty && cleared.primary == nil
                   && afterDelete.primary == "d" && afterDeleteTail.primary == "c",
               "刪 b,c → \(afterDelete.primary ?? "-")；刪 d,e → \(afterDeleteTail.primary ?? "-")")

        let wide = SelectionState(ids: ["a", "c", "e"], anchor: "a", primary: "e")
        let narrowed = SelectionLogic.restrict(wide, toVisible: ["b", "c", "d"])
        let kept = SelectionLogic.restrict(wide, toVisible: order)
        let none = SelectionLogic.restrict(wide, toVisible: ["b", "d"])
        record("多選：換區段／搜尋後選取裁成可見項目（主要選取與錨點跟著移），全部看不到就清空",
               narrowed == SelectionState(ids: ["c"], anchor: "c", primary: "c") && kept == wide && none == SelectionState(),
               "裁後 = \(narrowed.ids.sorted())")

        // MARK: DeletionPlanner（只用假路徑＋注入 probe，不建檔；路徑放在不存在的根目錄下，避開 /tmp 的 symlink）
        let root = URL(fileURLWithPath: "/utuvo-plan-root", isDirectory: true)
        let bundle = URL(fileURLWithPath: "/utuvo-plan-bundle/UTUVO Wallpaper.app", isDirectory: true)
        let w = root.appendingPathComponent("wallpapers", isDirectory: true)
        let six = w.appendingPathComponent("nature-dawn-abc123-6k.jpg")
        let sixSidecar = w.appendingPathComponent("nature-dawn-abc123-6k.provenance.json")
        let sixOriginal = root.appendingPathComponent("originals/nature-dawn-abc123.png")
        let noOriginal = w.appendingPathComponent("gradient-tide-zzz-6k.jpg")
        let inUse = w.appendingPathComponent("cosmic-nebula-q1-6k.jpg")
        let demo = bundle.appendingPathComponent("Contents/Resources/Demo/wallpapers/paper-landscape-demo-5k.jpg")
        let outside = URL(fileURLWithPath: "/utuvo-elsewhere/x-6k.jpg")
        let existing: Set<String> = [six.path, sixSidecar.path, sixOriginal.path, noOriginal.path, inUse.path, demo.path, outside.path]
        let plan = DeletionPlanner.plan(
            targets: [(six.lastPathComponent, six), (noOriginal.lastPathComponent, noOriginal),
                      (inUse.lastPathComponent, inUse), (demo.lastPathComponent, demo), (outside.lastPathComponent, outside)],
            dataRoot: root, bundleRoot: bundle, inUse: [inUse], probe: { existing.contains($0.path) ? .regular : .missing })
        let mapped = plan.items.first?.files == [six, sixSidecar, sixOriginal]
        let missingOriginalSkipped = plan.items.count == 2 && plan.items[1].files == [noOriginal]
        record("刪除計畫：6K 對應原圖＋sidecar；找不到原圖就略過原圖", mapped && missingOriginalSkipped,
               "第一張 \(plan.items.first?.files.count ?? 0) 個檔、第二張 \(plan.items.dropFirst().first?.files.count ?? 0) 個檔")
        let reasons = plan.skipped.map(\.reason)
        record("刪除計畫：略過正在當桌布、bundle 示範、資料根目錄外",
               reasons == [.inUseAsWallpaper, .bundledDemo, .outsideDataRoot],
               "略過 = \(reasons.map(\.rawValue))")
        let prefixTrick = DeletionPlanner.plan(targets: [("y", URL(fileURLWithPath: "/utuvo-plan-root-other/wallpapers/y-6k.jpg"))],
                                               dataRoot: root, bundleRoot: nil, inUse: [], probe: { _ in .regular })
        record("刪除計畫：名稱前綴相同的外部資料夾不算在資料根目錄內",
               prefixTrick.items.isEmpty && prefixTrick.skipped.first?.reason == .outsideDataRoot, "/utuvo-plan-root-other")
        let linkPlan = DeletionPlanner.plan(targets: [("s", six), ("l", noOriginal)], dataRoot: root, bundleRoot: nil, inUse: [],
            probe: { url in
                if url.path == sixSidecar.path || url.path == noOriginal.path { return .symbolicLink }
                return existing.contains(url.path) ? .regular : .missing
            })
        record("刪除計畫：symlink 主圖整張略過；symlink 附屬檔只略過那個檔並記錄",
               linkPlan.items.map(\.id) == ["s"] && linkPlan.items.first?.files == [six, sixOriginal]
                   && linkPlan.skipped.first?.reason == .symbolicLink && linkPlan.skippedFiles.map(\.url) == [sixSidecar],
               "略過 \(linkPlan.skipped.map(\.id))、附屬略過 \(linkPlan.skippedFiles.count) 個")

        // MARK: Dynamic 時間軸與場景庫
        let segments = DynamicPhase.timelineSegments
        let contiguous = zip(segments, segments.dropFirst()).allSatisfy { $0.end == $1.start }
            && segments.first?.start == 0 && segments.last?.end == 24
        let phasesMatch = segments.allSatisfy { segment in
            (segment.start..<segment.end).allSatisfy { hour in
                var parts = DateComponents(); parts.year = 2026; parts.month = 11; parts.day = 1; parts.hour = hour; parts.minute = 30
                return Calendar.current.date(from: parts).map(DynamicPhase.current(at:)) == segment.phase
            }
        }
        var noon = DateComponents(); noon.year = 2026; noon.month = 11; noon.day = 1; noon.hour = 18; noon.minute = 0
        let fraction = Calendar.current.date(from: noon).map { DynamicPhase.dayFraction(at: $0) } ?? -1
        record("Dynamic：時間軸 0–24 連續、夜晚跨午夜拆兩段、每小時色段與時段判斷一致、18:00 在 0.75",
               contiguous && phasesMatch && segments.filter { $0.phase == .night }.count == 2 && abs(fraction - 0.75) < 0.0001
                   && DynamicPhase.night.range == "21:00–06:00" && DynamicPhase.dusk.range == "18:00–21:00",
               "\(segments.map { "\($0.phase.rawValue)\($0.start)-\($0.end)" })")

        let sceneRoot = tempRoot.appendingPathComponent("scene-fixture", isDirectory: true)
        do {
            let jpeg = try makeGradientPNG(width: 32, height: 18)
            func makeScene(_ path: String, phases: [DynamicPhase], prompt: String?) throws -> URL {
                let folder = sceneRoot.appendingPathComponent(path, isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for phase in phases { try jpeg.write(to: folder.appendingPathComponent(phase.rawValue + ".jpg")) }
                if let prompt { try JSONSerialization.data(withJSONObject: ["prompt": prompt]).write(to: folder.appendingPathComponent("scene.json")) }
                return folder
            }
            _ = try makeScene("dynamic/scenes/A", phases: DynamicPhase.allCases, prompt: "湖畔木屋")
            _ = try makeScene("dynamic/scenes/B", phases: [.day, .dawn], prompt: "未完成")
            let builtIn = try makeScene("dynamic/mountain-hours", phases: DynamicPhase.allCases, prompt: nil)
            let listed = DynamicSceneLibrary.load(root: sceneRoot, builtIn: builtIn)
            let withoutBuiltIn = DynamicSceneLibrary.load(root: sceneRoot, builtIn: nil)
            record("Dynamic：場景庫只列四張都在的場景，加上內建示範",
                   listed.map(\.title) == ["湖畔木屋", "山稜的一天"] && listed.last?.isBuiltIn == true
                       && withoutBuiltIn.count == 1 && listed.first?.imageURL(.night).lastPathComponent == "night.jpg",
                   "列出 \(listed.map(\.title))")
        } catch {
            record("Dynamic：場景庫", false, "未預期錯誤 \(error)")
        }

        // MARK: 玻璃方塊資源
        if Bundle.main.bundleURL.pathExtension == "app" {
            let names = Set(IconTile.glassBySymbol.values)
            let missing = names.flatMap { name in [48, 72, 96].compactMap { size -> String? in
                let url = Bundle.main.resourceURL?.appendingPathComponent("GlassTiles/\(name)-\(size).png")
                return url.flatMap { NSImage(contentsOf: $0) }.map { Int($0.representations.first?.pixelsWide ?? 0) == size } == true ? nil : "\(name)-\(size)"
            } }
            record("玻璃方塊：13 色 × 48／72／96px 都在 bundle 且尺寸正確", names.count == 13 && missing.isEmpty,
                   missing.isEmpty ? "\(names.count * 3) 張" : "缺 \(missing.sorted())")
        }

        // MARK: 真的移到垃圾桶（隔離資料根目錄）
        let libRoot = tempRoot.appendingPathComponent("trash-fixture", isDirectory: true)
        var trashedToClean: [URL] = []
        let previous = getenv(LabPaths.dataDirectoryVariable).map { String(cString: $0) }
        setenv(LabPaths.dataDirectoryVariable, libRoot.path, 1)
        defer {
            if let previous { setenv(LabPaths.dataDirectoryVariable, previous, 1) }
            else { unsetenv(LabPaths.dataDirectoryVariable) }
        }
        do {
            let wallpapers = libRoot.appendingPathComponent("wallpapers", isDirectory: true)
            let originals = libRoot.appendingPathComponent("originals", isDirectory: true)
            try fm.createDirectory(at: wallpapers, withIntermediateDirectories: true)
            try fm.createDirectory(at: originals, withIntermediateDirectories: true)
            let png = try makeGradientPNG(width: 64, height: 36)
            let names = ["nature-dawn-t1", "nature-dawn-t2", "nature-dawn-t3"]
            for name in names {
                try png.write(to: wallpapers.appendingPathComponent("\(name)-6k.png"))
                if name != "nature-dawn-t2" {
                    try Data(#"{"origin":"resampled"}"#.utf8).write(to: wallpapers.appendingPathComponent("\(name)-6k.provenance.json"))
                }
                try png.write(to: originals.appendingPathComponent("\(name).png"))
            }
            // 資料根目錄內指向外部檔案的 symlink：主圖一張、t2 的 sidecar 一個。都必須略過，外部檔案原地不動。
            let outsideDir = tempRoot.appendingPathComponent("outside-fixture", isDirectory: true)
            try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
            let externalImage = outsideDir.appendingPathComponent("external.png")
            let externalSidecar = outsideDir.appendingPathComponent("external.provenance.json")
            try png.write(to: externalImage)
            try Data(#"{"origin":"native"}"#.utf8).write(to: externalSidecar)
            try fm.createSymbolicLink(at: wallpapers.appendingPathComponent("nature-dawn-link-6k.png"), withDestinationURL: externalImage)
            try fm.createSymbolicLink(at: wallpapers.appendingPathComponent("nature-dawn-t2-6k.provenance.json"), withDestinationURL: externalSidecar)
            let inUseURL = wallpapers.appendingPathComponent("nature-dawn-t3-6k.png")
            let model = AppModel(desktop: FakeDesktop(), outputRoot: libRoot, preferences: defaults,
                                 isBackgroundWorker: true, inUseWallpaperURLs: { [inUseURL] }, bundleRoot: nil)
            let order = model.wallpapers.map(\.id)
            model.editTags { try $0.addTag(name: "測試", color: "#0A84FF") }
            model.editTags { try $0.set("測試", assigned: true, for: Set(order)) }
            if let first = model.wallpapers.first(where: { $0.id == "nature-dawn-t1-6k.png" }) { model.toggleFavorite(first) }
            let ids = Set(order)
            let summary = model.trash(ids: ids, order: order)
            trashedToClean = summary.trashedURLs
            let goneT1 = !fm.fileExists(atPath: wallpapers.appendingPathComponent("nature-dawn-t1-6k.png").path)
                && !fm.fileExists(atPath: wallpapers.appendingPathComponent("nature-dawn-t1-6k.provenance.json").path)
                && !fm.fileExists(atPath: originals.appendingPathComponent("nature-dawn-t1.png").path)
                && !fm.fileExists(atPath: originals.appendingPathComponent("nature-dawn-t2.png").path)
            let inUseKept = fm.fileExists(atPath: inUseURL.path) && fm.fileExists(atPath: originals.appendingPathComponent("nature-dawn-t3.png").path)
            let inTrash = summary.trashedURLs.count == 5 && summary.trashedURLs.allSatisfy { fm.fileExists(atPath: $0.path) }
                && summary.trashedURLs.allSatisfy { $0.path.contains("/.Trash") }
            record("移到垃圾桶：主圖、sidecar、原圖都移進垃圾桶（不是永久刪除）",
                   summary.trashed == 2 && goneT1 && inTrash,
                   "移走 \(summary.trashed) 張／\(summary.trashedURLs.count) 個檔")
            record("移到垃圾桶：正在當桌布的略過且留在原地", summary.skippedInUse == 1 && inUseKept, model.statusMessage)
            let linkName = "nature-dawn-link-6k.png"
            let linksKept = fm.fileExists(atPath: externalImage.path) && fm.fileExists(atPath: externalSidecar.path)
                && DeletionPlanner.probe(wallpapers.appendingPathComponent(linkName)) == .symbolicLink
                && DeletionPlanner.probe(wallpapers.appendingPathComponent("nature-dawn-t2-6k.provenance.json")) == .symbolicLink
            record("移到垃圾桶：資料夾內指向外部的 symlink（主圖與 sidecar）都略過，外部檔案原地不動",
                   summary.skippedOther == 1 && linksKept, "略過其他 \(summary.skippedOther) 張")
            let survivors = [linkName, inUseURL.lastPathComponent]
            let cleanedUp = model.favoriteIDs.isEmpty && model.ids(withTag: "測試") == Set(survivors)
                && model.wallpapers.map(\.id) == survivors
                && model.selection.primary == inUseURL.lastPathComponent
            record("移到垃圾桶：收藏與標籤指派一併移除、reload、選到附近那張", cleanedUp,
                   "剩 \(model.wallpapers.count) 張、主要選取 = \(model.selection.primary ?? "-")")
        } catch {
            record("移到垃圾桶：流程", false, "未預期錯誤 \(error)")
        }
        // 找回垃圾桶裡的測試檔並清掉（只動本測試自己建的檔）。
        var trashLeft = 0
        for url in trashedToClean where url.path.contains("/.Trash") {
            try? fm.removeItem(at: url)
            if fm.fileExists(atPath: url.path) { trashLeft += 1 }
        }
        record("移到垃圾桶：測試結束把垃圾桶裡的測試檔清掉", trashLeft == 0, "\(trashedToClean.count) 個檔")
    }
}
