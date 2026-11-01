import Foundation
import AppKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// 自我測試。
///
/// 規則：
/// - 不讀憑證、不連網、不改桌布。
/// - 只用暫存 fixture，測完刪掉。
@MainActor
enum SelfTest {
    /// 只回傳固定 PNG 的假 provider（不連網）。
    struct FixtureProvider: ImageProvider {
        let data: Data
        func generateImage(prompt: String) async throws -> Data { data }
    }

    actor SceneFixture: SceneImageProvider {
        let data: Data
        var references: [Data] = []
        var generationCount = 0
        init(data: Data) { self.data = data }
        func generateImage(prompt: String) async throws -> Data { generationCount += 1; return data }
        func relight(reference: Data, prompt: String) async throws -> Data {
            references.append(reference); return data
        }
    }

    actor InterruptedProvider: ImageProvider {
        let data: Data
        var prompts: [String] = []
        init(data: Data) { self.data = data }
        func generateImage(prompt: String) async throws -> Data {
            prompts.append(prompt)
            if prompts.count == 2 { throw GenerationError.transport }
            return data
        }
    }

    /// 永遠失敗的假 provider（測錯誤路徑）。
    struct FailingProvider: ImageProvider {
        let message: String
        func generateImage(prompt: String) async throws -> Data {
            throw GenerationError.httpStatus(429)
        }
    }

    // MARK: - 測試用假物件（不碰真的 API、桌面、憑證）

    /// 假的桌布套用者：只回傳預先設定的結果並記錄呼叫，完全不碰真的桌面。
    @MainActor
    final class FakeDesktop: DesktopApplying {
        var results: [ScreenApplyResult] = []
        private(set) var appliedURLs: [URL] = []

        func setWallpaperOnAllScreens(_ url: URL) async -> [ScreenApplyResult] {
            appliedURLs.append(url)
            return results
        }

        var displays: [UInt32] = [1]
        private(set) var perDisplay: [(UInt32?, String)] = []

        func setWallpaper(_ url: URL, onDisplayID: UInt32?) async -> [ScreenApplyResult] {
            perDisplay.append((onDisplayID, url.lastPathComponent))
            return await setWallpaperOnAllScreens(url)
        }

        func displayIDs() -> [UInt32] { displays }
    }

    /// 假的圖片 provider：不連網。可以立刻回應、等到被取消、或直接回取消錯誤。
    final class FakeProvider: ImageProvider, @unchecked Sendable {
        enum Behavior {
            case immediate(Data)
            case blockUntilCancelled
            case throwsCancelled
        }
        let behavior: Behavior
        private(set) var callCount = 0

        init(behavior: Behavior) { self.behavior = behavior }

        func generateImage(prompt: String) async throws -> Data {
            callCount += 1
            switch behavior {
            case .immediate(let data):
                return data
            case .blockUntilCancelled:
                // 被取消時 Task.sleep 會立刻丟 CancellationError 上來。
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return Data()
            case .throwsCancelled:
                throw GenerationError.cancelled
            }
        }
    }

    static func run() async -> Int32 {
        var passed = 0
        var failed = 0
        var report: [String] = []

        func record(_ name: String, _ ok: Bool, _ detail: String) {
            if ok { passed += 1 } else { failed += 1 }
            let mark = ok ? "PASS" : "FAIL"
            report.append("[\(mark)] \(name) — \(detail)")
        }

        // 測試前後的桌布快照：確認自我測試沒有動到桌布。
        let before = DesktopController.currentScreens().map { NSWorkspace.shared.desktopImageURL(for: $0)?.path }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-selftest-\(UUID().uuidString)", isDirectory: true)
        let testSuite = "wallpaper-selftest-preferences-\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: testSuite)!
        defer { testDefaults.removePersistentDomain(forName: testSuite) }
        let previousDataRoot = getenv(LabPaths.dataDirectoryVariable).map { String(cString: $0) }
        setenv(LabPaths.dataDirectoryVariable, tempRoot.path, 1)
        defer {
            if let previousDataRoot { setenv(LabPaths.dataDirectoryVariable, previousDataRoot, 1) }
            else { unsetenv(LabPaths.dataDirectoryVariable) }
        }

        do {
            // 1) 憑證解析：正確的樣子
            let goodText = """
            # 這是註解
            EXAMPLE_KEY=test-value-123
            export OPENAI_API_KEY="quoted-value-456"
            EMPTY=
            """
            let parsed = CredentialStore.parse(goodText)
            let parseOK = parsed["EXAMPLE_KEY"] == "test-value-123"
                && parsed["OPENAI_API_KEY"] == "quoted-value-456"
                && parsed["EMPTY"] == ""
                && parsed.count == 3
            record("憑證解析：單行 KEY=value、去成對引號、忽略註解", parseOK,
                   "解析結果 key 數 = \(parsed.count)")

            // Isolated service only: never read, replace, or delete the user's real key.
            let keychain = KeychainCredentialStore(service: "com.utuvo.wallpaper-lab.selftest.\(UUID().uuidString)")
            var keychainOK = false
            do {
                defer { try? keychain.remove() }
                let fixture = "fixture-" + UUID().uuidString
                try keychain.save(fixture)
                let saved = try keychain.read() == fixture
                try keychain.save(fixture + "-replacement")
                let replaced = try keychain.read() == fixture + "-replacement"
                try keychain.remove()
                let removed = try !keychain.exists()
                keychainOK = saved && replaced && removed
            } catch { /* Report only the classified outcome, never a credential value. */ }
            record("鑰匙圈：隔離項目儲存、讀取、替換、移除", keychainOK, "使用獨立 UUID service，不接觸使用者金鑰")

            // 2) 憑證解析錯誤：不執行 shell、不吃多行指令
            let badText = """
            source ~/.evil/secret.sh
            rm -rf /tmp/whatever
            FOO
            EXAMPLE_KEY=$(whoami)
            key with space=1
            """
            let badParsed = CredentialStore.parse(badText)
            let badOK = badParsed.count == 1
                && badParsed["EXAMPLE_KEY"] == "$(whoami)"
                && badParsed["FOO"] == nil
                && badParsed["key with space"] == nil
            record("憑證解析錯誤：拒絕 source／無等號／含空白的 key，值不展開", badOK,
                   "只解析到 \(badParsed.count) 個 key")

            // 3) 空提示詞被擋下
            var emptyPromptRejected = false
            do {
                _ = try OpenAIImageProvider.validatePrompt("   \n ")
                emptyPromptRejected = false
            } catch let error as GenerationError {
                emptyPromptRejected = (error == .emptyPrompt)
            } catch {
                emptyPromptRejected = false
            }
            record("空提示詞：送出前就被擋下", emptyPromptRejected, "擋下空白提示詞")

        do {
            let suiteName = "selftest.language.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let startsSystem = AppLanguage.current(defaults: defaults) == .system
            AppLanguage.apply(.english, defaults: defaults)
            let english = AppLanguage.current(defaults: defaults) == .english
            AppLanguage.apply(.traditionalChinese, defaults: defaults)
            let chinese = AppLanguage.current(defaults: defaults) == .traditionalChinese
            AppLanguage.apply(.system, defaults: defaults)
            let backToSystem = AppLanguage.current(defaults: defaults) == .system
            let codes = AppLanguage.from(languageCode: "zh-Hant-TW") == .traditionalChinese
                && AppLanguage.from(languageCode: "en-GB") == .english
                && AppLanguage.from(languageCode: "ja") == .system
            defaults.removePersistentDomain(forName: suiteName)
            record("語言選擇：英文／繁中／跟隨系統可寫入並讀回", startsSystem && english && chinese && backToSystem && codes,
                   "隔離 defaults 網域，不動使用者設定")
        }

            // 4) 圖片 decode + 6K 輸出
            let sourcePNG = (try? Self.makeGradientPNG(width: 3840, height: 2160)) ?? Data()
            let sourceSize = ImageResampler.pixelSize(of: sourcePNG)
            let decodeOK = sourceSize?.width == 3840 && sourceSize?.height == 2160
            let sceneProvider = SceneFixture(data: sourcePNG)
            let sceneDirectory = tempRoot.appendingPathComponent("scene-fixture")
            var sceneOK = false
            var priorityOK = false
            do {
                let scene = try await DynamicGenerator(provider: sceneProvider).generate(
                    prompt: "isolated scene", directory: sceneDirectory, progress: { _ in })
                try scene.publish()
                let description = try DynamicScene.describe(DynamicScene.heicURL)
                let references = await sceneProvider.references
                _ = try await DynamicGenerator(provider: sceneProvider).generate(
                    prompt: "isolated scene", directory: sceneDirectory, progress: { _ in })
                let calls = await sceneProvider.generationCount
                let edits = await sceneProvider.references.count
                sceneOK = calls == 1 && edits == 3 && references.allSatisfy { $0 == sourcePNG }
                    && description["width"] as? Int == 6144 && description["height"] as? Int == 3456
                    && description["frames"] as? Int == 4
                let desktop = FakeDesktop()
                desktop.results = [ScreenApplyResult(index: 0, name: "fixture", displayID: 1,
                    originalWallpaper: nil, applied: true, readbackMatched: true, error: nil)]
                let model = AppModel(desktop: desktop, preferences: testDefaults, isBackgroundWorker: true)
                model.setRotationMode(.hourly)
                testDefaults.set(true, forKey: "dynamic.enabled")
                testDefaults.set(sceneDirectory.path, forKey: "dynamic.activeDirectory")
                model.refreshAutomationOwnership()
                for hour in [6, 9, 18, 21] {
                    let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
                    await model.performBackgroundRotation(at: date)
                }
                model.rotationTick()
                priorityOK = desktop.appliedURLs.map { $0.lastPathComponent } == ["dawn.jpg", "day.jpg", "dusk.jpg", "night.jpg"]
                    && !model.isRotationRunning && model.isDynamicActive
                model.setRotationMode(.off)
                testDefaults.set(false, forKey: "dynamic.enabled")
            } catch {}
            record("日夜生成：一張基準、三次同參考編修、6K四幀HEIC、重試不重生", sceneOK,
                   "隔離假API與資料；原生PNG及6K時段檔保留")
            record("日夜排程：四時段邊界切換且一般輪換無法覆蓋", priorityOK,
                   "使用假桌面、隔離偏好與控制日期，不改系統時間")
            record("圖片 decode：讀出原生像素尺寸", decodeOK,
                   "原生 = \(sourceSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "讀不出")")

            let resampled = try? ImageResampler.resampleToJPEG6K(pngData: sourcePNG)
            let resampledSize = resampled.flatMap { ImageResampler.pixelSize(of: $0) }
            let fiveKOK = resampledSize?.width == 6144 && resampledSize?.height == 3456
            record("6K 輸出：CoreGraphics 重採樣成 6144×3456", fiveKOK,
                   "輸出 = \(resampledSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "失敗")")

            // 重採樣後的平均色要接近原圖（證明不是空白圖）
            let sourceMean = resampled.flatMap { _ in Self.meanColor(of: sourcePNG) }
            let outputMean = resampled.flatMap { Self.meanColor(of: $0) }
            let colorOK: Bool
            if let a = sourceMean, let b = outputMean {
                colorOK = abs(a.r - b.r) < 0.08 && abs(a.g - b.g) < 0.08 && abs(a.b - b.b) < 0.08
            } else {
                colorOK = false
            }
            record("6K 輸出：重採樣內容與原圖一致", colorOK, "平均色比較")

            // 5) 資料夾不存在
            let missing = tempRoot.appendingPathComponent("does-not-exist/deeper", isDirectory: true)
            let missingItem = WallpaperLibrary.makeWallpaper(from: missing.appendingPathComponent("nope.png"))
            let emptyStateOK = missingItem == nil
            record("資料夾不存在：讀不到圖片時回傳空狀態而不是當掉", emptyStateOK,
                   "makeWallpaper 回傳 nil")

            // 6) 生成流程（用 fixture，不連網）＋不覆蓋
            let service = GenerationService(provider: FixtureProvider(data: sourcePNG))
            var generatedOK = false
            var noOverwriteOK = false
            var nativeSidecarOK = true
            var fiveKSidecarOK = true
            var sidecarDetail = "沒有 sidecar"
            do {
                let first = try await service.generate(count: 2, outputRoot: tempRoot, progress: { _, _ in })
                let second = try await service.generate(count: 1, outputRoot: tempRoot, progress: { _, _ in })
                generatedOK = first.count == 2 && second.count == 1
                let names = Set((first + second).flatMap { [$0.nativeURL, $0.wallpaperURL] })
                noOverwriteOK = names.count == 6      // 3 張 ×（原生 PNG ＋ 6K JPEG）
                for item in first {
                    let nativeURL = URL(fileURLWithPath: item.nativeURL)
                    let wallpaperURL = URL(fileURLWithPath: item.wallpaperURL)
                    let nativeExists = FileManager.default.fileExists(atPath: nativeURL.path)
                    let fiveKExists = FileManager.default.fileExists(atPath: wallpaperURL.path)
                    if !nativeExists || !fiveKExists { generatedOK = false }

                    // 原生與 6K 各有各的 sidecar：原生標 native、6K 標 resampled。
                    // 共用同一個 sidecar 會讓原生圖被誤標成重採樣。
                    let nativeSidecar = nativeURL.deletingPathExtension().appendingPathExtension("provenance.json")
                    let fiveKSidecar = wallpaperURL.deletingPathExtension().appendingPathExtension("provenance.json")
                    if nativeSidecar == fiveKSidecar {
                        nativeSidecarOK = false
                        fiveKSidecarOK = false
                        sidecarDetail = "兩個 sidecar 是同一個檔"
                    }
                    let nativeOrigin = SelfTest.origin(of: nativeSidecar)
                    let fiveKOrigin = SelfTest.origin(of: fiveKSidecar)
                    if nativeOrigin != "native" {
                        nativeSidecarOK = false
                        sidecarDetail = "原生 sidecar origin = \(nativeOrigin ?? "讀不到")"
                    }
                    if fiveKOrigin != "resampled" {
                        fiveKSidecarOK = false
                        sidecarDetail = "6K sidecar origin = \(fiveKOrigin ?? "讀不到")"
                    }

                    // 讀取端（WallpaperLibrary）必須照 sidecar 標示。
                    let nativeData = (try? Data(contentsOf: nativeURL)) ?? Data()
                    let fiveKData = (try? Data(contentsOf: wallpaperURL)) ?? Data()
                    let nativeSize = ImageResampler.pixelSize(of: nativeData)
                    let fiveKSize = ImageResampler.pixelSize(of: fiveKData)
                    let resolvedNative = WallpaperLibrary.resolveOrigin(for: nativeURL,
                                                                       width: Int(nativeSize?.width ?? 0),
                                                                       height: Int(nativeSize?.height ?? 0))
                    let resolvedFiveK = WallpaperLibrary.resolveOrigin(for: wallpaperURL,
                                                                       width: Int(fiveKSize?.width ?? 0),
                                                                       height: Int(fiveKSize?.height ?? 0))
                    if resolvedNative != .native {
                        nativeSidecarOK = false
                        sidecarDetail = "原生圖讀出來是 \(resolvedNative.label)"
                    }
                    if resolvedFiveK != .resampled {
                        fiveKSidecarOK = false
                        sidecarDetail = "6K 圖讀出來是 \(resolvedFiveK.label)"
                    }
                    if sidecarDetail == "沒有 sidecar" {
                        sidecarDetail = "原生 native／6K resampled，兩個 sidecar 不同檔"
                    }
                }
            } catch {
                generatedOK = false
                noOverwriteOK = false
                nativeSidecarOK = false
                fiveKSidecarOK = false
            }
            record("生成流程（fixture）：原生 PNG、6K JPEG 都寫出來", generatedOK, "檔案存在性")
            record("生成流程（fixture）：新檔隨機 id、不覆蓋既有檔", noOverwriteOK, "6 個檔名互異")
            record("metadata：原生 PNG 的 sidecar 標 native（不是重採樣）", nativeSidecarOK, sidecarDetail)
            record("metadata：6K 成品自己的 sidecar 標 resampled（非原生／非 AI 放大）", fiveKSidecarOK, sidecarDetail)

            // 7) HTTP 錯誤不得假裝成功
            let failing = GenerationService(provider: FailingProvider(message: "boom"))
            var failureSurfaced = false
            do {
                _ = try await failing.generate(count: 1, outputRoot: tempRoot, progress: { _, _ in })
                failureSurfaced = false
            } catch let error as GenerationError {
                failureSurfaced = (error == .httpStatus(429))
            } catch {
                failureSurfaced = false
            }
            record("HTTP 錯誤：直接往上拋，不假裝成功", failureSurfaced, "429 會被回報")

            // 7b) 回應解析（純函式，不連網）
            let fakeResponse: [String: Any] = [
                "created": 1,
                "data": [["b64_json": sourcePNG.base64EncodedString()]]
            ]
            var extractOK = false
            if let json = try? JSONSerialization.data(withJSONObject: fakeResponse) {
                if let extracted = try? OpenAIImageProvider.extractImage(from: json),
                   extracted == sourcePNG {
                    extractOK = true
                }
            }
            record("回應解析：b64_json 正確取出圖片資料", extractOK, "解出 PNG 資料")

            var extractFailOK = false
            let emptyResponse = try? JSONSerialization.data(withJSONObject: ["data": [Any]()])
            if let emptyResponse {
                do {
                    _ = try OpenAIImageProvider.extractImage(from: emptyResponse)
                    extractFailOK = false
                } catch let error as GenerationError {
                    extractFailOK = (error == .invalidResponse)
                } catch {
                    extractFailOK = false
                }
            }
            record("回應解析：沒有可用資料時報錯而不是假裝成功", extractFailOK, "invalidResponse")

            // 8) 錯誤訊息不得帶出憑證
            let fixtureValue = ["fixture", "value", "for", "leak", "check"].joined(separator: "-")
            let parsedFixture = CredentialStore.parse("EXAMPLE_KEY=" + fixtureValue)
            let message = GenerationError.httpStatus(401).localizedDescription
            let noSecretLeak = !message.contains(fixtureValue) && (parsedFixture["EXAMPLE_KEY"] == fixtureValue)
            record("憑證不外洩：錯誤訊息不含 key", noSecretLeak, "檢查錯誤字串")

            // 9) 輪換接線：模式 → rotation.mode → 計時器 → 設為桌面
            let rotDesktop = FakeDesktop()
            let rotModel = AppModel(desktop: rotDesktop,
                                     serviceFactory: { GenerationService(provider: FakeProvider(behavior: .immediate(sourcePNG))) },
                                     credentialAvailable: { false }, preferences: testDefaults)
            rotModel.setRotationMode(.fiveMinutes)
            let modeWired = (rotModel.rotationMode == .fiveMinutes) && rotModel.isRotationRunning
            record("輪換：模式接到 rotation.mode，計時器真的啟動", modeWired,
                   "rotationMode = \(rotModel.rotationMode.rawValue)，isRunning = \(rotModel.isRotationRunning)")

            rotModel.rotation.tick()          // 計時器到期時呼叫的同一個入口
            let ticked = await SelfTest.waitUntil { !rotDesktop.appliedURLs.isEmpty }
            let appliedIsListed = rotDesktop.appliedURLs.first.map { url in
                rotModel.wallpapers.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
            } ?? false
            rotModel.setRotationMode(.off)
            let stopped = !rotModel.isRotationRunning
            record("輪換：計時器觸發會換張並設為桌面", ticked && appliedIsListed,
                   rotModel.wallpapers.isEmpty
                       ? "清單是空的（Delivery/wallpapers 沒有圖），測不出輪換效果"
                       : "已套用 \(rotDesktop.appliedURLs.count) 次")
            record("輪換：切回關閉會停掉計時器", stopped, "isRunning = \(rotModel.isRotationRunning)")

            // Persistent resume, a fresh service instance, and an exhausted budget.
            let resumeRoot = tempRoot.appendingPathComponent("resume")
            let interrupted = InterruptedProvider(data: sourcePNG)
            do {
                _ = try await GenerationService(provider: interrupted).generate(
                    count: 3, outputRoot: resumeRoot, batchDay: "fixture", progress: { _, _ in })
            } catch {}
            var checkpoint = try? DailyBatch.load(root: resumeRoot, day: "fixture")
            let preserved = checkpoint?.completed.count == 1 && checkpoint?.attempts == [1, 1, 0]
            let firstURL = checkpoint?.completed.first?.wallpaperURL
            let backoff = checkpoint?.canResume() == false
            checkpoint?.retryAfter = Date.distantPast
            try? checkpoint?.save(root: resumeRoot, day: "fixture")
            let resumed = try? await GenerationService(provider: interrupted).generate(
                count: 3, outputRoot: resumeRoot, batchDay: "fixture", progress: { _, _ in })
            let prompts = await interrupted.prompts
            record("每日續作：保留成品、冷卻後只補未完成主題、重開服務仍有效",
                   preserved && backoff && resumed?.count == 3
                   && resumed?.first?.wallpaperURL == firstURL && prompts.count == 4
                   && prompts[1] == prompts[2] && prompts[0] != prompts[3],
                   "中斷於第2張；續作只呼叫第2、3主題")
            var exhausted = DailyBatch(count: 1, attempts: [3])
            exhausted.retryAfter = Date.distantPast
            record("每日續作：三次請求上限、完成後不重跑、權限錯誤不補試",
                   !exhausted.canResume()
                   && (try? DailyBatch.load(root: resumeRoot, day: "fixture").canResume()) == false
                   && !DailyBatch.isRetryable(GenerationError.httpStatus(401)),
                   "無真實API請求，無等待實際冷卻時間")

            let placements = ["/Applications/UTUVO Wallpaper.app/Contents/MacOS/WallpaperLab": false,
                              "/Users/me/Applications/UTUVO Wallpaper.app/Contents/MacOS/WallpaperLab": false,
                              "/private/var/folders/x/AppTranslocation/ABC/d/UTUVO Wallpaper.app/Contents/MacOS/WallpaperLab": true,
                              "/Volumes/UTUVO Wallpaper/UTUVO Wallpaper.app/Contents/MacOS/WallpaperLab": true]
            let misplaced = placements.filter { BackgroundService.isTemporaryLocation(URL(fileURLWithPath: $0.key)) != $0.value }
            record("背景註冊：從 DMG／隔離暫存位置執行時拒絕啟用，應用程式資料夾放行",
                   misplaced.isEmpty, misplaced.isEmpty ? "\(placements.count) 例" : "誤判 \(misplaced.keys.sorted())")

            let categoryCases = [("nature-dawn-yab2mict-6k.jpg", "自然"), ("botanical-macro-daily-2026-11-01-6k.jpg", "自然"),
                                 ("gradient-tide-yyzw2mck-5k.jpg", "抽象"), ("paper-landscape-5k.png", "極簡"),
                                 ("watercolor-meadow-7y7q8kak-5k.jpg", "水彩"), ("nature-dawnish.jpg", "其他"),
                                 ("my-photo.jpg", "其他")]
            let categoryMisses = categoryCases.filter { WallpaperLibrary.category(forFileName: $0.0) != $0.1 }
            record("分類：依檔名範本 id 自動歸類，前綴相似但不相同不誤判",
                   categoryMisses.isEmpty && WallpaperLibrary.categoryOrder.last == "其他"
                   && Set(WallpaperLibrary.categoryOrder).count == WallpaperLibrary.categoryOrder.count,
                   categoryMisses.isEmpty ? "\(categoryCases.count) 例" : "誤判 \(categoryMisses.map(\.0))")

            let plist = try? BackgroundService.registrationPlist(
                executableURL: tempRoot.appendingPathComponent("App With Spaces.app/Contents/MacOS/WallpaperLab"),
                dataDirectory: tempRoot)
            let config = plist.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            let args = config?["ProgramArguments"] as? [String]
            let environment = config?["EnvironmentVariables"] as? [String: String]
            let calendar = config?["StartCalendarInterval"] as? [[String: Int]]
            record("背景註冊：登入載入、每分鐘檢查、四時段整點喚醒、路徑含空格、無憑證環境",
                   config?["RunAtLoad"] as? Bool == true && config?["StartInterval"] as? Int == 60
                   && calendar?.map { $0["Hour"] ?? -1 } == [6, 9, 18, 21]
                   && calendar?.allSatisfy { $0["Minute"] == 0 && $0.count == 2 } == true
                   && args?.count == 2 && args?.last == "--background-tick"
                   && args?.first?.contains("App With Spaces.app") == true
                   && environment == [LabPaths.dataDirectoryVariable: tempRoot.path]
                   && config?["KeepAlive"] == nil, "只產生隔離 plist，不註冊 launchd")

            let backgroundDesktop = FakeDesktop()
            backgroundDesktop.results = [ScreenApplyResult(index: 0, name: "fixture", displayID: 1,
                originalWallpaper: nil, applied: true, readbackMatched: true, error: nil)]
            let backgroundModel = AppModel(desktop: backgroundDesktop, preferences: testDefaults, isBackgroundWorker: true)
            backgroundModel.setRotationMode(.hourly)
            let start = Date()
            await backgroundModel.performBackgroundRotation(at: start)
            let firstID = backgroundModel.selectedID
            let resumedModel = AppModel(desktop: backgroundDesktop, preferences: testDefaults, isBackgroundWorker: true)
            await resumedModel.performBackgroundRotation(at: start.addingTimeInterval(59))
            let noEarlyRotation = backgroundDesktop.appliedURLs.count == 1
            await resumedModel.performBackgroundRotation(at: start.addingTimeInterval(3601))
            record("背景輪換：重開後保存游標、每小時一次、只用6K",
                   noEarlyRotation && backgroundDesktop.appliedURLs.count == 2
                   && firstID != resumedModel.selectedID
                   && resumedModel.selected?.pixelWidth == 6144 && resumedModel.selected?.pixelHeight == 3456,
                   "假桌面跨兩個 worker model，未改動真實桌面")
            resumedModel.setRotationMode(.off)

            // 第一梯隊：頻率、暫停、每顆螢幕不同張、上一張
            let intervalsOK = RotationController.Mode.fifteenMinutes.interval == 900
                && RotationController.Mode.thirtyMinutes.interval == 1800 && RotationController.Mode.daily.interval == 86_400
                && RotationController.Mode.allCases.count == 7
            let planOK = RotationPlan.next(pool: ["a", "b", "c"], after: "b", count: 3) == ["c", "a", "b"]
                && RotationPlan.next(pool: ["a", "b"], after: "gone", count: 1) == ["a"]
                && RotationPlan.next(pool: [], after: nil, count: 2).isEmpty
                && RotationPlan.previous(in: ["a", "b", "c"], existing: ["a", "b", "c"])?.id == "b"
                && RotationPlan.previous(in: ["a", "b", "c"], existing: ["a", "c"])?.id == "a"
                && RotationPlan.previous(in: ["a", "a"], existing: ["a"]) == nil
            let urlCases: [(String, WallpaperCommand?)] = [
                ("utuvo-wallpaper://next", .next), ("UTUVO-Wallpaper://Previous", .previous), ("utuvo-wallpaper:favorite", .favorite),
                ("utuvo-wallpaper://toggle-pause", .togglePause), ("utuvo-wallpaper://delete", nil), ("https://next", nil)]
            let urlMiss = urlCases.filter { URL(string: $0.0).flatMap(WallpaperCommand.init(url:)) != $0.1 }
            record("捷徑網址：next／previous／favorite／toggle-pause 解析、大小寫不拘、其他網址與未知指令不動作",
                   urlMiss.isEmpty, urlMiss.isEmpty ? "\(urlCases.count) 例" : "\(urlMiss.map(\.0))")
            record("輪換頻率與挑圖：7 種頻率、游標往後挑、圖池少時重複、上一張略過已刪除",
                   intervalsOK && planOK, "純函式")

            let multiDesktop = FakeDesktop()
            multiDesktop.displays = [11, 22, 33]
            multiDesktop.results = [ScreenApplyResult(index: 0, name: "fixture", displayID: 1,
                originalWallpaper: nil, applied: true, readbackMatched: true, error: nil)]
            let multiModel = AppModel(desktop: multiDesktop, preferences: testDefaults, isBackgroundWorker: true)
            multiModel.targetDisplayID = nil
            multiModel.rotationPerDisplay = true
            multiModel.setRotationMode(.fifteenMinutes)
            testDefaults.removeObject(forKey: "rotation.lastAttempt")
            testDefaults.removeObject(forKey: "rotation.history")
            let t0 = Date()
            multiModel.setRotationPaused(true)
            await multiModel.performBackgroundRotation(at: t0)
            let pausedOK = multiDesktop.perDisplay.isEmpty
            multiModel.setRotationPaused(false)
            await multiModel.performBackgroundRotation(at: t0)
            let firstRound = multiDesktop.perDisplay
            let distinctDisplays = firstRound.map { $0.0 } == [11, 22, 33]
            let poolSize = multiModel.rotationPool().count
            let distinctImages = Set(firstRound.map { $0.1 }).count == min(3, poolSize)
            await multiModel.performBackgroundRotation(at: t0.addingTimeInterval(600))
            let notYet = multiDesktop.perDisplay.count == 3
            await multiModel.performBackgroundRotation(at: t0.addingTimeInterval(901))
            let secondRound = multiDesktop.perDisplay.count == 6
            record("每顆螢幕不同張：暫停時不換、三顆螢幕各一張、15 分鐘內不重換",
                   pausedOK && distinctDisplays && distinctImages && notYet && secondRound,
                   "圖池 \(poolSize) 張；第一輪 \(firstRound.map { "\($0.0 ?? 0):\($0.1)" })")

            multiModel.rotationPerDisplay = false
            await multiModel.skipToNext(at: t0.addingTimeInterval(999))
            let beforePrevious = multiModel.selectedID
            await multiModel.skipToNext(at: t0.addingTimeInterval(1000))
            let afterNext = multiModel.selectedID
            await multiModel.applyPrevious(at: t0.addingTimeInterval(1001))
            let history = testDefaults.stringArray(forKey: "rotation.history") ?? []
            let skipKeepsBackground = (testDefaults.object(forKey: "rotation.lastAttempt") as? Date) == t0.addingTimeInterval(1001)
            record("上一張／立即下一張：下一張換圖、上一張回到前一張、背景計時重算",
                   afterNext != nil && afterNext != beforePrevious && multiModel.selectedID == beforePrevious
                   && history.last == multiModel.selectedID && skipKeepsBackground,
                   "前 \(beforePrevious ?? "nil") → 下 \(afterNext ?? "nil") → 回 \(multiModel.selectedID ?? "nil")")
            multiModel.setRotationMode(.off)
            for key in ["rotation.perDisplay", "rotation.paused", "rotation.history", "rotation.lastAttempt", "rotation.lastID"] {
                testDefaults.removeObject(forKey: key)
            }

            // 10) 取消：舊 Task 還在收尾時必須維持 busy，第二批不能開
            let cancelProvider = FakeProvider(behavior: .blockUntilCancelled)
            let cancelModel = AppModel(desktop: FakeDesktop(),
                                        serviceFactory: { GenerationService(provider: cancelProvider) },
                                        credentialAvailable: { false }, preferences: testDefaults)
            cancelModel.startGeneration(count: 1)
            // 等第一批真的走到 provider（否則取消會在請求送出前就擋掉，測不到「進行中取消」）
            let reachedProvider = await SelfTest.waitUntil { cancelProvider.callCount >= 1 }
            let busyAfterStart = cancelModel.isGenerating
            cancelModel.cancelGeneration()
            let busyDuringCancel = cancelModel.isGenerating
            cancelModel.startGeneration(count: 1)
            let refused = cancelModel.errorMessage == "已經有一個生成作業在進行中。"
            let unwound = await SelfTest.waitUntil { !cancelModel.isGenerating }
            record("生成：開始後進入 busy 狀態", busyAfterStart && reachedProvider,
                   "isGenerating = \(busyAfterStart)")
            record("取消：Task 還沒收尾時維持 busy，第二批被擋下",
                   busyDuringCancel && refused,
                   "取消中 busy = \(busyDuringCancel)，第二批被拒 = \(refused)")
            record("取消：Task unwind 後才清 busy 並回報已取消，且被擋下的第二批沒有再打一次 API",
                   unwound && cancelModel.statusMessage == "已取消生成。" && cancelProvider.callCount == 1,
                   "statusMessage = \(cancelModel.statusMessage)，provider 被呼叫 \(cancelProvider.callCount) 次")

            // 11) provider 直接回取消錯誤：要分類成「已取消」，不是「生成失敗」
            let cancelledProvider = FakeProvider(behavior: .throwsCancelled)
            let cancelledModel = AppModel(desktop: FakeDesktop(),
                                          serviceFactory: { GenerationService(provider: cancelledProvider) },
                                          credentialAvailable: { false }, preferences: testDefaults)
            cancelledModel.startGeneration(count: 1)
            let cancelledUnwound = await SelfTest.waitUntil { !cancelledModel.isGenerating }
            record("取消分類：GenerationError.cancelled 回報為已取消，不是生成失敗",
                   cancelledUnwound
                       && cancelledModel.statusMessage == "已取消生成。"
                       && cancelledModel.errorMessage == nil,
                   "statusMessage = \(cancelledModel.statusMessage)，errorMessage = \(cancelledModel.errorMessage ?? "無")")

            // 12) 每日：缺憑證不記當日 attempt，補上憑證後當天仍會執行
            let suiteName = "wallpaper-selftest-\(UUID().uuidString)"
            var dailyOK = false
            var dailyDetail = "測試用 UserDefaults suite 建不起來"
            if let suiteDefaults = UserDefaults(suiteName: suiteName) {
                let daily = DailyScheduler(defaults: suiteDefaults)
                let dailyProvider = FakeProvider(behavior: .immediate(sourcePNG))
                var credentialReady = false
                let dailyModel = AppModel(desktop: FakeDesktop(),
                                          daily: daily,
                                          outputRoot: tempRoot.appendingPathComponent("daily", isDirectory: true),
                                          serviceFactory: { GenerationService(provider: dailyProvider) },
                                          credentialAvailable: { credentialReady }, preferences: testDefaults)
                dailyModel.setDailyMode(.ten)
                let reopenedModel = AppModel(desktop: FakeDesktop(),
                                             daily: DailyScheduler(defaults: suiteDefaults),
                                             outputRoot: tempRoot.appendingPathComponent("daily-reopened", isDirectory: true),
                                             serviceFactory: { GenerationService(provider: dailyProvider) },
                                             credentialAvailable: { false }, preferences: testDefaults)
                let remembered = reopenedModel.dailyMode == .ten
                let templates = PromptTemplate.rotated(count: 10)
                let distinctThemes = templates.count == 10 && Set(templates.map { $0.id }).count == 10
                dailyModel.checkDaily()
                let notMarked = !daily.alreadyAttempted()
                let notStarted = dailyProvider.callCount == 0
                // 補上憑證後，當天仍然要能跑
                credentialReady = true
                var heldLease = try? FileLease.acquire(at: tempRoot.appendingPathComponent("daily/.generation.lock"))
                let busyNotClaimed = withExtendedLifetime(heldLease) {
                    dailyModel.checkDaily()
                    return heldLease != nil && !daily.alreadyAttempted() && !dailyModel.isGenerating
                }
                heldLease = nil
                dailyModel.checkDaily()
                let started = await SelfTest.waitUntil { dailyProvider.callCount >= 1 }
                let markedNow = daily.alreadyAttempted()
                dailyModel.checkDaily()
                record("每日工作鎖：忙碌不耗用當日機會、同日不啟動第二批",
                       busyNotClaimed && markedNow && dailyProvider.callCount == 1,
                       "隔離檔案鎖與假 provider，沒有 API 請求")
                dailyModel.cancelGeneration()          // 收尾：不用真的產生 10 張
                _ = await SelfTest.waitUntil { !dailyModel.isGenerating }
                dailyOK = remembered && distinctThemes && notMarked && notStarted && started && markedNow
                dailyDetail = "重開保留每日10張 = \(remembered)、10主題互異 = \(distinctThemes)；缺憑證未記錄 = \(notMarked)、未啟動 = \(notStarted)；補憑證後有啟動 = \(started)、已記錄 = \(markedNow)"
                suiteDefaults.removePersistentDomain(forName: suiteName)
            }
            record("每日：保留10張選擇、10主題互異、缺憑證不記當日 attempt", dailyOK, dailyDetail)

            // 13) 套用結果：0 顆螢幕或讀回不符都不能顯示成功
            let applyDesktop = FakeDesktop()
            let applyModel = AppModel(desktop: applyDesktop,
                                      serviceFactory: { GenerationService(provider: FakeProvider(behavior: .immediate(sourcePNG))) },
                                      credentialAvailable: { false }, preferences: testDefaults)
            let testWallpaper = Wallpaper(id: "fixture",
                                          url: tempRoot.appendingPathComponent("fixture.png"),
                                          pixelWidth: 6144, pixelHeight: 3456,
                                          origin: .resampled)
            applyDesktop.results = []
            await applyModel.apply(testWallpaper)
            let zeroScreenFailed = (applyModel.errorMessage != nil)
                && !applyModel.statusMessage.contains("已設為目前桌布")
            let zeroScreenStatus = applyModel.statusMessage

            applyDesktop.results = [ScreenApplyResult(index: 0, name: "螢幕一", displayID: 1,
                                                      originalWallpaper: nil, applied: true,
                                                      readbackMatched: false, error: nil)]
            await applyModel.apply(testWallpaper)
            let readbackFailed = (applyModel.errorMessage != nil)
                && applyModel.statusMessage.contains("已嘗試")
            let readbackStatus = applyModel.statusMessage

            applyDesktop.results = [ScreenApplyResult(index: 0, name: "螢幕一", displayID: 1,
                                                      originalWallpaper: nil, applied: true,
                                                      readbackMatched: true, error: nil)]
            await applyModel.apply(testWallpaper)
            let successShown = (applyModel.errorMessage == nil)
                && applyModel.statusMessage.contains("讀回相符 1 顆")
            let successStatus = applyModel.statusMessage

            record("套用：沒有螢幕時不可顯示成功", zeroScreenFailed, "statusMessage = \(zeroScreenStatus)")
            record("套用：讀回不符時不可顯示成功", readbackFailed, "statusMessage = \(readbackStatus)")
            record("套用：讀回相符時才顯示成功", successShown, "statusMessage = \(successStatus)")

            // 14) 輪換／清單只掃 wallpapers/ 的 6K 成品，originals/ 不進清單
            let scanDirs = LabPaths.scanDirectories()
            let originalsScanned = scanDirs.contains { $0.standardizedFileURL == LabPaths.originalsDir.standardizedFileURL }
            let listed = WallpaperLibrary.load()
            let listedFromOriginals = listed.contains {
                $0.url.deletingLastPathComponent().standardizedFileURL == LabPaths.originalsDir.standardizedFileURL
            }
            let originalsKept = FileManager.default.fileExists(atPath: LabPaths.originalsDir.path)
            record("輪換清單：只掃 wallpapers/ 的 6K 成品，originals/ 不進清單",
                   !originalsScanned && !listedFromOriginals && LabPaths.deliveryRoot == tempRoot.standardizedFileURL,
                   "掃 \(scanDirs.count) 個資料夾、清單 \(listed.count) 張、originals 有被掃 = \(originalsScanned)")
            record("輪換清單：originals/ 檔案仍保留在磁碟（Finder 可看）", originalsKept,
                   LabPaths.originalsDir.lastPathComponent)
        }

        // 16) 標籤、解析度、多選、刪除計畫、移到垃圾桶
        await runLibraryTests(tempRoot: tempRoot, defaults: testDefaults, record: record)

        // 15) 確認自我測試沒有動到桌布

        // 9) 確認自我測試沒有動到桌布
        let after = DesktopController.currentScreens().map { NSWorkspace.shared.desktopImageURL(for: $0)?.path }
        let desktopUntouched = before == after
        record("自我測試不修改桌布：前後桌布路徑一致", desktopUntouched, "比對 \(before.count) 顆螢幕")

        // 清掉暫存 fixture
        if FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let cleaned = !FileManager.default.fileExists(atPath: tempRoot.path)
        record("測試完刪掉暫存 fixture", cleaned, tempRoot.lastPathComponent)

        for line in report { print(line) }
        print("—")
        print("自我測試：\(passed) 通過，\(failed) 失敗")
        return failed == 0 ? 0 : 1
    }

    // MARK: - fixture 工具

    /// 讀 sidecar 的 origin 欄位。
    static func origin(of sidecarURL: URL) -> String? {
        guard let data = try? Data(contentsOf: sidecarURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["origin"] as? String
    }

    /// 等到條件成立或逾時。
    ///
    /// 在 MainActor 上執行，條件閉包因此可以安全讀 @MainActor 的狀態；
    /// 用來等「非同步收尾」的結果（例如取消後 Task 真的 unwind）。
    static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// 造一張漸層 PNG（3840×2160）。
    static func makeGradientPNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw GenerationError.decoding
        }
        let colors = [NSColor(calibratedRed: 0.12, green: 0.35, blue: 0.72, alpha: 1).cgColor,
                      NSColor(calibratedRed: 0.90, green: 0.62, blue: 0.28, alpha: 1).cgColor]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1]) else {
            throw GenerationError.decoding
        }
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: CGFloat(width), y: CGFloat(height)),
                               options: [])
        guard let image = ctx.makeImage() else { throw GenerationError.decoding }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw GenerationError.decoding
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw GenerationError.decoding }
        return data as Data
    }

    /// 平均色（0...1）。
    static func meanColor(of data: Data) -> (r: Double, g: Double, b: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = 64, height = 36
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var r = 0, g = 0, b = 0, n = 0
        var i = 0
        while i + 3 < buffer.count {
            r += Int(buffer[i]); g += Int(buffer[i + 1]); b += Int(buffer[i + 2]); n += 1
            i += 4
        }
        guard n > 0 else { return nil }
        return (Double(r) / Double(n) / 255.0, Double(g) / Double(n) / 255.0, Double(b) / Double(n) / 255.0)
    }
}
