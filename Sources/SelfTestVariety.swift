import Foundation

/// 每日 10 張變化／自選風格／自己的想法，以及日夜 AI 自動排程的自測。
/// 不連網：圖片來源全是假的；隔離資料夾與 defaults。
extension SelfTest {
    struct FailingScene: SceneImageProvider {
        func generateImage(prompt: String) async throws -> Data { throw GenerationError.httpStatus(500) }
        func relight(reference: Data, prompt: String) async throws -> Data { throw GenerationError.httpStatus(500) }
    }

    actor PromptRecorder: ImageProvider {
        let data: Data
        var prompts: [String] = []
        init(data: Data) { self.data = data }
        func generateImage(prompt: String) async throws -> Data { prompts.append(prompt); return data }
    }

    static func runVarietyTests(tempRoot: URL, defaults: UserDefaults,
                                record: (String, Bool, String) -> Void) async {
        // MARK: 每日計畫
        let all = DailyRecipe()
        let dayA = DailyPlan.make(day: "2026-11-02", count: 10, recipe: all)
        let dayA2 = DailyPlan.make(day: "2026-11-02", count: 10, recipe: all)
        let dayB = DailyPlan.make(day: "2026-11-03", count: 10, recipe: all)
        let sameDayStable = dayA == dayA2
        let changed = zip(dayA, dayB).filter { $0.prompt != $1.prompt }.count
        let allStyles = Set(dayA.map(\.templateID)).count == 10
        record("每日 10 張：同一天固定、隔天主題／配色會換", sameDayStable && changed >= 8 && allStyles,
               "隔天不同 \(changed)／10 張、風格 \(Set(dayA.map(\.templateID)).count) 種")

        let weekDistinct = Set((0..<7).flatMap { DailyPlan.make(day: "2026-11-0\($0 + 1)", count: 10, recipe: all).map(\.prompt) }).count
        record("每日 10 張：一週 70 張提示詞幾乎不重複", weekDistinct >= 65, "不同 \(weekDistinct)／70")

        // 每個風格連續 N 天（N＝主題數）主題都不重複，隔天一定換。
        var cycleOK = true
        var cal0 = Calendar(identifier: .gregorian)
        cal0.timeZone = TimeZone(identifier: "UTC")!
        let start0 = cal0.date(from: DateComponents(year: 2026, month: 11, day: 3))!
        let fmt = DateFormatter()
        fmt.calendar = cal0; fmt.timeZone = cal0.timeZone; fmt.dateFormat = "yyyy-MM-dd"
        for template in PromptTemplate.shared {
            let pool = DailyPlan.subjectPool(template)
            let subjects = (0..<pool.count).map { offset -> String in
                let day = fmt.string(from: cal0.date(byAdding: .day, value: offset, to: start0)!)
                let prompt = DailyPlan.make(day: day, count: 1, recipe: DailyRecipe(styles: [template.id])).first!.prompt
                return pool.first { prompt.contains("Subject: \($0).") } ?? "?"
            }
            if Set(subjects).count != pool.count { cycleOK = false }
        }
        record("每日 10 張：每個風格把主題輪完一圈才重複（隔天一定換主題）", cycleOK,
               "風格 \(PromptTemplate.shared.count) 種、主題 \(PromptTemplate.shared.map { DailyPlan.subjectPool($0).count }.reduce(0, +)) 個")

        let picked = DailyRecipe(styles: ["watercolor-meadow", "cosmic-nebula"], idea: "")
        let pickedPlan = DailyPlan.make(day: "2026-11-02", count: 10, recipe: picked)
        let onlyPicked = pickedPlan.allSatisfy { picked.styles.contains($0.templateID) }
        let slugsUnique = Set(pickedPlan.map(\.slug)).count == 10
        let subjectsUnique = Set(pickedPlan.map(\.prompt)).count == 10
        record("自選風格：只用選到的風格，檔名與主題不重複", onlyPicked && slugsUnique && subjectsUnique,
               pickedPlan.map(\.slug).joined(separator: ","))

        let idea = DailyRecipe(styles: [], idea: "  台北的老公寓陽台  ")
        let ideaPlan = DailyPlan.make(day: "2026-11-02", count: 10, recipe: idea)
        // 純色、漸層是本機畫的，不吃自己的 Prompt；其他每張都要畫它。
        let ideaUsed = ideaPlan.filter { !LocalArt.isLocal($0.prompt) }.allSatisfy { $0.prompt.contains("Subject: 台北的老公寓陽台.") }
        let ideaStyles = Set(ideaPlan.map(\.templateID)).count == 10
        record("自己的想法：每張都畫它、用不同風格表現", ideaUsed && ideaStyles, ideaPlan[0].prompt)

        let suite = "selftest.recipe.\(UUID().uuidString)"
        let recipeDefaults = UserDefaults(suiteName: suite)!
        DailyRecipe(styles: ["gradient-tide", "no-such-style"], idea: String(repeating: "長", count: 300)).save(recipeDefaults)
        let loaded = DailyRecipe.load(recipeDefaults)
        recipeDefaults.removePersistentDomain(forName: suite)
        record("每日設定存讀：不認得的風格丟掉、想法限 200 字", loaded.styles == ["gradient-tide"] && loaded.idea.count == 200,
               "styles=\(loaded.styles) idea=\(loaded.idea.count)")

        // 續作：改設定也照原計畫，檔名對得上。
        let batchRoot = tempRoot.appendingPathComponent("variety-batch", isDirectory: true)
        let png = (try? makeGradientPNG(width: 64, height: 36)) ?? Data()
        do {
            let recorder = PromptRecorder(data: png)
            let service = GenerationService(provider: recorder, recipe: DailyRecipe(styles: aiOnlyRecipe.styles, idea: idea.idea))
            _ = try await service.generate(count: 3, outputRoot: batchRoot, batchDay: "2026-11-02") { _, _ in }
            let prompts = await recorder.prompts
            let stored = try DailyBatch.load(root: batchRoot, day: "2026-11-02").plan ?? []
            let names = (try? FileManager.default.contentsOfDirectory(atPath: batchRoot.appendingPathComponent("originals").path)) ?? []
            let filesMatch = stored.allSatisfy { planned in names.contains { $0.hasPrefix(planned.slug + "-daily-2026-11-02") } }
            // 同一天換設定再跑：已完成，不會重送。
            let again = GenerationService(provider: recorder, recipe: all)
            _ = try await again.generate(count: 3, outputRoot: batchRoot, batchDay: "2026-11-02") { _, _ in }
            let after = await recorder.prompts.count
            record("每日批次：計畫存進進度檔，送出的就是計畫、檔名照 slug、續作不重送",
                   prompts == stored.map(\.prompt) && filesMatch && after == 3 && prompts.allSatisfy { $0.contains("台北") },
                   "送出 \(prompts.count)、計畫 \(stored.count)、檔案 \(names.filter { $0.hasSuffix(".png") }.count)")
        } catch {
            record("每日批次：計畫存進進度檔，送出的就是計畫、檔名照 slug、續作不重送", false, "\(error)")
        }

        // 分類：選「自然」＝兩個自然風格；取消後回到全部。
        var byCategory = DailyRecipe()
        byCategory.setCategory("自然", on: true)
        let natureIDs = PromptTemplate.shared.filter { $0.category == "自然" }.map(\.id)
        let natureOK = byCategory.styles == natureIDs && byCategory.categories == ["自然"]
            && byCategory.templates.allSatisfy { $0.category == "自然" }
        byCategory.setCategory("宇宙", on: true)
        let twoOK = byCategory.categories == ["自然", "宇宙"]
        byCategory.setCategory("自然", on: false); byCategory.setCategory("宇宙", on: false)
        record("分類選單：選分類＝該分類所有風格，取消後回到全部", natureOK && twoOK && byCategory.styles.isEmpty
               && byCategory.templates.count == PromptTemplate.shared.count, byCategory.styles.joined(separator: ","))

        // 手動「產生桌布」用自己的分類與 Prompt，不吃每日排程的設定。
        do {
            let manualRoot = tempRoot.appendingPathComponent("manual-recipe", isDirectory: true)
            let manualSuite = "selftest.manual.\(UUID().uuidString)"
            let manualDefaults = UserDefaults(suiteName: manualSuite)!
            defer { manualDefaults.removePersistentDomain(forName: manualSuite) }
            let recorder = PromptRecorder(data: png)
            let model = AppModel(desktop: FakeDesktop(), outputRoot: manualRoot,
                                 serviceFactory: { GenerationService(provider: recorder) },
                                 credentialAvailable: { true }, preferences: manualDefaults, isBackgroundWorker: true)
            model.dailyRecipe = DailyRecipe(styles: [], idea: "每日的主題")
            var manual = DailyRecipe(styles: [], idea: "手動的 Prompt：雨中的電話亭")
            manual.setCategory("插畫", on: true)
            model.manualRecipe = manual
            let started = model.startGeneration(count: 2)
            _ = await waitUntil({ !model.isGenerating }, timeout: 60)
            let prompts = await recorder.prompts
            let reloaded = DailyRecipe.load(manualDefaults, prefix: DailyRecipe.manualPrefix)
            record("手動產生：用彈窗裡的分類＋自己的 Prompt，不影響每日設定、會記住",
                   started && prompts.count == 2 && prompts.allSatisfy { $0.contains("雨中的電話亭") && !$0.contains("每日的主題") }
                       && prompts.allSatisfy { $0.hasPrefix("Editorial illustration") } && reloaded == manual
                       && DailyRecipe.load(manualDefaults).idea == "每日的主題",
                   "送出 \(prompts.count) 張")
        }

        // AI 靈感：只從選到的分類挑、換一個跟現在不同的；中英照介面語言。
        let cosmic = PromptInspiration.ideas["宇宙"]!.map(\.zh)
        var counter = 0
        let picks = (0..<20).map { _ -> String in
            counter += 7
            return PromptInspiration.pick(categories: ["宇宙"], current: cosmic[0], chinese: true, random: { counter })
        }
        let englishIdea = PromptInspiration.pick(categories: ["水彩"], current: "", chinese: false)
        // 純色、漸層沒有主題，其他每個分類都要有點子。
        let allCovered = DailyRecipe.categories.filter { !$0.hasPrefix("純色") && !$0.hasPrefix("漸層") }
            .allSatisfy { (PromptInspiration.ideas[$0]?.count ?? 0) >= 20 }
        let spread = Set((0..<400).map { _ in PromptInspiration.pick(categories: [], current: "", chinese: true) })
        record("AI 靈感：只挑選到的分類、不重複目前內容、英文介面給英文、每個分類 20 句以上、搭配細節後很少重複",
               picks.allSatisfy { pick in pick != cosmic[0] && cosmic.contains { pick.hasPrefix($0) } } && Set(picks).count > 1
                   && PromptInspiration.ideas["水彩"]!.map(\.en).contains { englishIdea.hasPrefix($0) } && allCovered
                   && spread.count >= 300,
               "400 次有 \(spread.count) 種：" + picks.prefix(2).joined(separator: "／"))

        // 純色／漸層：本機畫出正確尺寸的 PNG，生成時不送 API。
        let solidPNG = LocalArt.render("local:solid:#264653", width: 384, height: 216)
        let gradientPNG = LocalArt.render("local:gradient:#0F2027,#203A43,#2C5364|120", width: 384, height: 216)
        let solidSize = solidPNG.flatMap { ImageResampler.pixelSize(of: $0) }
        let badSpec = LocalArt.render("local:solid:#XYZ", width: 10, height: 10) == nil && LocalArt.render("a mountain", width: 10, height: 10) == nil
        var localNoAPI = false
        do {
            let localRoot = tempRoot.appendingPathComponent("local-art", isDirectory: true)
            let recorder = PromptRecorder(data: png)
            let service = GenerationService(provider: recorder, recipe: DailyRecipe(styles: ["solid-color", "gradient-soft"]))
            let made = try await service.generate(count: 4, outputRoot: localRoot, batchDay: "2026-11-03") { _, _ in }
            let sent = await recorder.prompts.count
            let files = (try? FileManager.default.contentsOfDirectory(atPath: localRoot.appendingPathComponent("wallpapers").path))?.filter { $0.hasSuffix("6k.jpg") } ?? []
            localNoAPI = made.count == 4 && sent == 0 && files.count == 4
        } catch { localNoAPI = false }
        record("純色／漸層：本機畫圖、尺寸正確、規格錯就不畫、生成時完全不送 API",
               solidSize?.width == 384 && solidSize?.height == 216 && gradientPNG != nil && badSpec && localNoAPI,
               "localNoAPI=\(localNoAPI)")

        let legacy = DailyPlan.legacy(day: "2026-11-02", count: 10)
        record("舊進度檔沒有計畫：檔名照舊輪替", legacy.map(\.slug) == PromptTemplate.rotated(count: 10).map(\.id), "")

        var snap = BackgroundSnapshot()
        snap.error = "舊的鎖忙碌錯誤"           // 舊版留下、沒有 batchError
        snap.recordError(nil, fromBatch: false)
        let staleCleared = snap.error == nil
        snap.recordError("批次失敗", fromBatch: true)
        snap.recordError(nil, fromBatch: false)
        let batchKept = snap.error == "批次失敗"
        snap.recordError(nil, fromBatch: true)
        record("背景狀態：舊錯誤沒再發生就清掉；每日批次失敗保留到下一批",
               staleCleared && batchKept && snap.error == nil, "")

        // MARK: 日夜 AI 自動：排程
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }
        let monday = date(2026, 11, 2), sunday = date(2026, 11, 8), nextMonday = date(2026, 11, 9)
        let weekly = DynamicAutoPlanner.period(for: monday, frequency: .weekly, calendar: cal)
        let periodsOK = weekly == DynamicAutoPlanner.period(for: sunday, frequency: .weekly, calendar: cal)
            && weekly != DynamicAutoPlanner.period(for: nextMonday, frequency: .weekly, calendar: cal)
            && DynamicAutoPlanner.period(for: monday, frequency: .daily, calendar: cal) == "2026-11-02"
            && DynamicAutoPlanner.period(for: monday, frequency: .off, calendar: cal) == nil
        record("AI 自動：每天＝日期、每週＝同一 ISO 週、關閉不排", periodsOK, weekly ?? "nil")

        let first = DynamicAutoPlanner.due(state: nil, now: monday, frequency: .weekly, calendar: cal, chinese: true)
        var done = first!
        done.attempts = 1
        done.recordSuccess()
        let sameWeek = DynamicAutoPlanner.due(state: done, now: sunday, frequency: .weekly, calendar: cal, chinese: true)
        let newWeek = DynamicAutoPlanner.due(state: done, now: nextMonday, frequency: .weekly, calendar: cal, chinese: true)
        var failing = first!
        failing.attempts = 1
        failing.recordFailure(retryable: true, now: monday)
        let tooSoon = DynamicAutoPlanner.due(state: failing, now: monday.addingTimeInterval(60), frequency: .weekly, calendar: cal, chinese: true)
        let retry = DynamicAutoPlanner.due(state: failing, now: monday.addingTimeInterval(31 * 60), frequency: .weekly, calendar: cal, chinese: true)
        var hard = first!
        hard.attempts = 1
        hard.recordFailure(retryable: false, now: monday)
        let stopped = DynamicAutoPlanner.due(state: hard, now: monday.addingTimeInterval(3600), frequency: .weekly, calendar: cal, chinese: true)
        record("AI 自動：這期做完不重做、下一期換新主題、暫時錯誤 30 分鐘後續作、其他錯誤這期停",
               first != nil && sameWeek == nil && newWeek != nil && newWeek!.subject != done.subject
                   && newWeek!.recentSubjects.contains(done.subject) && tooSoon == nil && retry == failing && stopped == nil,
               "\(first?.prompt ?? "-") → \(newWeek?.prompt ?? "-")")

        let manualAgain = DynamicAutoPlanner.manual(state: done, now: sunday, frequency: .weekly, calendar: cal, chinese: true)
        let manualResume = DynamicAutoPlanner.manual(state: hard, now: monday, frequency: .weekly, calendar: cal, chinese: true)
        record("AI 自動：手動再生成會換主題；沒做完的手動可再續作",
               manualAgain.sceneID != done.sceneID && !manualAgain.completed && manualAgain.attempts == 0
                   && manualResume.sceneID == hard.sceneID && manualResume.attempts < DynamicAutoState.maxAttempts,
               manualAgain.prompt)

        // 日夜提示詞：照使用者寫的畫風畫，不強迫寫實風景；換時段保留畫風、不憑空加木屋。
        let ghibli = "隨意的吉卜力風格"
        let basePrompts = [ScenePrompt.base(ghibli, canvas: .desktop), ScenePrompt.base(ghibli, canvas: .phone)]
        let relights = ScenePrompt.phases.flatMap { [ScenePrompt.relight($0, canvas: .desktop), ScenePrompt.relight($0, canvas: .phone)] }
        record("日夜提示詞：保留使用者的畫風、不限風景；換時段只改光線、保留畫風",
               basePrompts.allSatisfy { $0.contains(ghibli) && $0.contains("Follow the art style")
                   && !$0.contains("photographic") && !$0.contains("landscape:") }
                   && basePrompts[0].contains("16:9") && basePrompts[1].contains("9:16")
                   && relights.allSatisfy { $0.contains("Keep its art style") && !$0.contains("cabin") && !$0.contains("photograph") }
                   && ScenePrompt.relight("night", canvas: .phone).contains("night"),
               "\(basePrompts[0].count)／\(relights.count) 段")
        let autoPicks = (0..<120).map { DynamicAutoPlanner.pick(period: "v\($0)", season: .spring, recent: [], chinese: true) }
        let indoorIDs: Set<String> = ["reading-nook", "corner-cafe", "window-cat", "studio-desk", "old-kitchen", "bookshop"]
        let pickedStyles = Set(autoPicks.compactMap { pick in DynamicAutoPlanner.styles.first { pick.prompt.hasSuffix($0.zh) }?.zh })
        record("AI 自動：題材不只風景（室內、街角、小動物），畫風也會輪替",
               autoPicks.contains { indoorIDs.contains($0.subject) } && pickedStyles.count >= 4,
               "室內 \(autoPicks.filter { indoorIDs.contains($0.subject) }.count)／120、畫風 \(pickedStyles.count) 種")

        let summer = (0..<40).map { DynamicAutoPlanner.pick(period: "p\($0)", season: .summer, recent: [], chinese: true).subject }
        let winterOnly = Set(DynamicAutoPlanner.subjects.filter(\.winterOnly).map(\.id))
        let recent = Array(DynamicAutoPlanner.subjects.prefix(6).map(\.id))
        let avoided = (0..<40).allSatisfy { !recent.contains(DynamicAutoPlanner.pick(period: "q\($0)", season: .autumn, recent: recent, chinese: false).subject) }
        let english = DynamicAutoPlanner.pick(period: "x", season: .spring, recent: [], chinese: false).prompt.contains("spring")
        let southern = DynamicAutoPlanner.season(for: date(2026, 7, 1), calendar: cal, southern: true) == .winter
        record("AI 自動：雪景只在冬天、避開最近 6 個、英文介面用英文、南半球季節相反",
               summer.allSatisfy { !winterOnly.contains($0) } && avoided && english && southern, "")

        var cancelled = first!
        cancelled.attempts = 1
        cancelled.recordFailure(retryable: DynamicAutoState.isRetryable(GenerationError.cancelled), now: monday)
        record("AI 自動：取消（GenerationError.cancelled）算可續作，不會整期停掉",
               cancelled.attempts == 1 && cancelled.retryAfter != nil
                   && DynamicAutoState.isRetryable(CancellationError()) && !DynamicAutoState.isRetryable(GenerationError.httpStatus(400)),
               "attempts=\(cancelled.attempts)")

        // MARK: 日夜 AI 自動：AppModel 接線（假圖片來源）
        let autoRoot = tempRoot.appendingPathComponent("auto-fixture", isDirectory: true)
        let autoSuite = "selftest.auto.\(UUID().uuidString)"
        let autoDefaults = UserDefaults(suiteName: autoSuite)!
        defer { autoDefaults.removePersistentDomain(forName: autoSuite) }
        let fixture = SceneFixture(data: png)
        let model = AppModel(desktop: FakeDesktop(), outputRoot: autoRoot, credentialAvailable: { true },
                             preferences: autoDefaults, isBackgroundWorker: true)
        model.sceneProviderFactory = { fixture }
        model.checkDynamicAuto(now: monday)
        let offIdle = !model.isGenerating && model.dynamicAutoState == nil
        model.dynamicAutoFrequency = .weekly
        let persisted = DynamicAutoFrequency.load(autoDefaults) == .weekly
        model.checkDynamicAuto(now: monday)
        _ = await waitUntil({ !model.isGenerating }, timeout: 60)
        let state = model.dynamicAutoState
        let directory = autoRoot.appendingPathComponent("dynamic/scenes/\(state?.sceneID ?? "-")")
        let complete = DynamicSceneEntry.isComplete(directory)
        model.checkDynamicAuto(now: sunday)
        let noRepeat = !model.isGenerating
        let calls = await fixture.generationCount
        record("AI 自動接線：關閉時不動；每週開啟會生成一組完整四時段、記錄完成、同週不再生成",
               offIdle && persisted && state?.completed == true && state?.attempts == 1 && complete && noRepeat && calls == 1,
               "state=\(state?.prompt ?? "nil") complete=\(complete) calls=\(calls)")

        // 別的行程正在生成（拿著生成鎖）：自動檢查安靜跳過，不記次數、不報錯。
        let busyRoot = tempRoot.appendingPathComponent("auto-busy", isDirectory: true)
        let busySuite = "selftest.autobusy.\(UUID().uuidString)"
        let busyDefaults = UserDefaults(suiteName: busySuite)!
        defer { busyDefaults.removePersistentDomain(forName: busySuite) }
        try? FileManager.default.createDirectory(at: busyRoot, withIntermediateDirectories: true)
        let holder = try? FileLease.acquire(at: busyRoot.appendingPathComponent(".generation.lock"))
        let busyModel = AppModel(desktop: FakeDesktop(), outputRoot: busyRoot, credentialAvailable: { true },
                                 preferences: busyDefaults, isBackgroundWorker: true)
        busyModel.sceneProviderFactory = { fixture }
        busyModel.dynamicAutoFrequency = .daily
        busyModel.checkDynamicAuto(now: monday)
        record("AI 自動：別的行程在生成時，背景檢查安靜跳過（不報錯、不記次數）",
               holder != nil && busyModel.errorMessage == nil && !busyModel.isGenerating && busyModel.dynamicAutoState == nil,
               "error=\(busyModel.errorMessage ?? "nil")")
        withExtendedLifetime(holder) {}

        let failRoot = tempRoot.appendingPathComponent("auto-fail", isDirectory: true)
        let failSuite = "selftest.autofail.\(UUID().uuidString)"
        let failDefaults = UserDefaults(suiteName: failSuite)!
        defer { failDefaults.removePersistentDomain(forName: failSuite) }
        var keyPresent = false
        let failModel = AppModel(desktop: FakeDesktop(), outputRoot: failRoot, credentialAvailable: { keyPresent },
                                 preferences: failDefaults, isBackgroundWorker: true)
        failModel.sceneProviderFactory = { FailingScene() }
        failModel.dynamicAutoFrequency = .daily
        failModel.checkDynamicAuto(now: monday)
        let noKeyNoCount = failModel.dynamicAutoState == nil && !failModel.isGenerating
        keyPresent = true
        failModel.checkDynamicAuto(now: monday)
        _ = await waitUntil({ !failModel.isGenerating }, timeout: 30)
        let failed = failModel.dynamicAutoState
        record("AI 自動失敗：缺 key 不記次數；伺服器錯誤記 1 次、30 分鐘後再試",
               noKeyNoCount && failed?.attempts == 1 && failed?.completed == false && failed?.retryAfter != nil
                   && failModel.errorMessage != nil,
               "attempts=\(failed?.attempts ?? -1)")
    }
}
