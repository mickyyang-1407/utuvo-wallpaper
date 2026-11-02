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
        let allStyles = Set(dayA.map(\.templateID)).count == PromptTemplate.shared.count
        record("每日 10 張：同一天固定、隔天主題／配色會換", sameDayStable && changed >= 8 && allStyles,
               "隔天不同 \(changed)／10 張、風格 \(Set(dayA.map(\.templateID)).count) 種")

        let weekDistinct = Set((0..<7).flatMap { DailyPlan.make(day: "2026-11-0\($0 + 1)", count: 10, recipe: all).map(\.prompt) }).count
        record("每日 10 張：一週 70 張提示詞幾乎不重複", weekDistinct >= 65, "不同 \(weekDistinct)／70")

        let picked = DailyRecipe(styles: ["watercolor-meadow", "cosmic-nebula"], idea: "")
        let pickedPlan = DailyPlan.make(day: "2026-11-02", count: 10, recipe: picked)
        let onlyPicked = pickedPlan.allSatisfy { picked.styles.contains($0.templateID) }
        let slugsUnique = Set(pickedPlan.map(\.slug)).count == 10
        let subjectsUnique = Set(pickedPlan.map(\.prompt)).count == 10
        record("自選風格：只用選到的風格，檔名與主題不重複", onlyPicked && slugsUnique && subjectsUnique,
               pickedPlan.map(\.slug).joined(separator: ","))

        let idea = DailyRecipe(styles: [], idea: "  台北的老公寓陽台  ")
        let ideaPlan = DailyPlan.make(day: "2026-11-02", count: 10, recipe: idea)
        let ideaUsed = ideaPlan.allSatisfy { $0.prompt.contains("Subject: 台北的老公寓陽台.") }
        let ideaStyles = Set(ideaPlan.map(\.templateID)).count == PromptTemplate.shared.count
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
            let service = GenerationService(provider: recorder, recipe: idea)
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

        let legacy = DailyPlan.legacy(day: "2026-11-02", count: 10)
        record("舊進度檔沒有計畫：檔名照舊輪替", legacy.map(\.slug) == PromptTemplate.rotated(count: 10).map(\.id), "")

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
