import Foundation
import AppKit

/// 命令列模式。
enum CLIMode {
    case exportDynamic(URL)
    case generateOnce(outputDirectory: URL, count: Int, styles: [String])
    case inspectDisplays
    case desktopSmoke(imageURL: URL)
    case selfTest
    case backgroundTick
    case backgroundStatus
    case dynamicSwitchTest
}

/// CLI 進入點。全部在 MainActor 上執行（AppKit 限制）。
@MainActor
enum CLI {
    nonisolated static func parse(_ arguments: [String]) -> CLIMode? {
        var index = 0
        var count = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--dynamic-switch-test": return .dynamicSwitchTest
            case "--background-tick": return .backgroundTick
            case "--background-status": return .backgroundStatus
            case "--export-dynamic":
                guard index + 1 < arguments.count else {
                    FileHandle.standardError.write(Data("用法：--export-dynamic <輸出.heic>\n".utf8))
                    exit(64)
                }
                return .exportDynamic(URL(fileURLWithPath: arguments[index + 1]))
            case "--self-test":
                return .selfTest
            case "--inspect-displays":
                return .inspectDisplays
            case "--generate-once":
                guard index + 1 < arguments.count else {
                    FileHandle.standardError.write(Data("用法：--generate-once <輸出資料夾> [--count N]\n".utf8))
                    exit(64)
                }
                index += 1
                let dir = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath, isDirectory: true)
                if let flagIndex = arguments.firstIndex(of: "--count"), flagIndex + 1 < arguments.count,
                   let value = Int(arguments[flagIndex + 1]) {
                    count = max(1, min(10, value))
                }
                // --styles a,b,c：只用這些風格（範本 id）；純色／漸層不需要 API key。
                var styles: [String] = []
                if let flagIndex = arguments.firstIndex(of: "--styles"), flagIndex + 1 < arguments.count {
                    styles = arguments[flagIndex + 1].split(separator: ",").map(String.init)
                }
                return .generateOnce(outputDirectory: dir, count: count, styles: styles)
            case "--desktop-smoke":
                guard index + 1 < arguments.count else {
                    FileHandle.standardError.write(Data("用法：--desktop-smoke <絕對路徑的圖片>\n".utf8))
                    exit(64)
                }
                index += 1
                let path = (arguments[index] as NSString).expandingTildeInPath
                return .desktopSmoke(imageURL: URL(fileURLWithPath: path))
            default:
                index += 1
            }
        }
        return nil
    }

    static func run(_ mode: CLIMode) async -> Int32 {
        switch mode {
        case .dynamicSwitchTest:
            guard UserDefaults.standard.bool(forKey: "dynamic.enabled") else { return fail("請先在App設定日夜桌布。") }
            guard let lease = try? FileLease.acquire(at: LabPaths.deliveryRoot.appendingPathComponent(".background-tick.lock")) else { return fail("背景正在執行，請稍後。") }
            defer { withExtendedLifetime(lease) {} }
            let model = AppModel(isBackgroundWorker: true)
            var rows: [[String: Any]] = []
            var ok = true
            for (phase, hour) in [(DynamicPhase.dawn, 6), (.day, 9), (.dusk, 18), (.night, 21)] {
                let date = Calendar.current.date(bySettingHour: hour, minute: 1, second: 0, of: Date())!
                await model.performBackgroundRotation(at: date)
                rows.append(["phase": phase.rawValue, "success": model.errorMessage == nil, "result": model.statusMessage])
                if model.errorMessage != nil { ok = false }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await model.performBackgroundRotation(at: Date())
            emit(["mode": "controlled-time-real-desktop", "results": rows,
                  "restoredCurrentPhase": model.errorMessage == nil, "nativeHEICAllDayTested": false])
            return ok && model.errorMessage == nil ? 0 : 1
        case .backgroundTick:
            return await BackgroundRunner.tick()
        case .backgroundStatus:
            emit(["enabled": BackgroundService.isEnabled(), "loaded": BackgroundService.isLoaded(),
                  "statusFile": BackgroundSnapshot.url.path,
                  "credentialSource": CredentialStore.sourceDescription()])
            return 0
        case .exportDynamic(let url):
            do {
                try DynamicScene.export(to: url)
                emit(try DynamicScene.describe(url))
                return 0
            } catch {
                return fail(error.localizedDescription)
            }
        case .selfTest:
            return await SelfTest.run()
        case .inspectDisplays:
            return await inspectDisplays()
        case .generateOnce(let dir, let count, let styles):
            return await generateOnce(directory: dir, count: count, styles: styles)
        case .desktopSmoke(let url):
            return await desktopSmoke(url)
        }
    }

    // MARK: - 輸出

    private static func emit(_ object: Any) {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let text = String(data: data, encoding: .utf8) else {
            print("輸出 JSON 失敗")
            return
        }
        print(text)
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data(("錯誤：" + message + "\n").utf8))
        return 1
    }

    // MARK: - --inspect-displays（唯讀）

    private static func inspectDisplays() async -> Int32 {
        let snapshots = DesktopController.snapshots()
        var payload: [[String: Any]] = []
        for snapshot in snapshots {
            let item: [String: Any] = [
                "index": snapshot.index,
                "name": snapshot.name,
                "displayID": snapshot.displayID,
                "frame": snapshot.frame,
                "pixelSize": "\(snapshot.pixelWidth) × \(snapshot.pixelHeight)",
                "backingScaleFactor": snapshot.backingScaleFactor,
                "currentWallpaper": snapshot.currentWallpaper ?? NSNull(),
                "readOnly": true
            ]
            payload.append(item)
        }
        emit([
            "mode": "inspect-displays",
            "displayCount": payload.count,
            "note": "只讀模式，未做任何變更；僅反映目前 Space 的畫面。驗證只用 NSWorkspace 的桌布路徑讀回，不擷取畫面（沒有像素級證據）。",
            "displays": payload
        ])
        return 0
    }

    // MARK: - --generate-once

    private static func generateOnce(directory: URL, count: Int, styles: [String]) async -> Int32 {
        let recipe = DailyRecipe(styles: PromptTemplate.shared.map(\.id).filter(styles.contains))
        let provider: any ImageProvider
        if let key = CredentialStore.load() { provider = OpenAIImageProvider(apiKey: key) }
        else if recipe.isLocalOnly && !recipe.styles.isEmpty { provider = LocalOnlyProvider() }
        else { return fail(GenerationError.missingCredential.localizedDescription) }
        let service = GenerationService(provider: provider, recipe: recipe)
        do {
            let results = try await service.generate(count: count, outputRoot: directory) { done, total in
                print("已產生 \(done)/\(total)")
            }
            emit([
                "mode": "generate-once",
                "outputDirectory": directory.path,
                "count": results.count,
                "generated": results.map { result -> [String: Any] in
                    [
                        "title": result.title,
                        "native": result.nativeURL,
                        "nativePixelSize": result.nativePixelSize,
                        "wallpaper": result.wallpaperURL,
                        "wallpaperPixelSize": result.wallpaperPixelSize,
                        "origin": result.origin
                    ]
                }
            ])
            return 0
        } catch is CancellationError {
            return fail("已取消。")
        } catch {
            let message = (error as? GenerationError)?.localizedDescription ?? error.localizedDescription
            return fail(message)
        }
    }

    // MARK: - --desktop-smoke

    private static func desktopSmoke(_ imageURL: URL) async -> Int32 {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            return fail("找不到圖片：\(imageURL.path)")
        }
        let dryRun = CommandLine.arguments.contains("--dry-run")
        let force = CommandLine.arguments.contains("--force")
        let screens = DesktopController.currentScreens()
        guard !screens.isEmpty else { return fail("找不到任何螢幕。") }

        var results: [[String: Any]] = []
        var anyModified = false
        var anyFailed = false
        var anySkipped = false

        for (index, screen) in screens.enumerated() {
            let displayID = DesktopController.displayID(of: screen)
            let original = NSWorkspace.shared.desktopImageURL(for: screen)
            // 先保存原本的縮放／裁切設定，還原時才不會改掉使用者原本的選擇。
            let originalOptions = DesktopController.currentImageOptions(for: screen)
            var item: [String: Any] = [
                "index": index,
                "name": screen.localizedName,
                "displayID": Int(displayID)
            ]

            guard let original else {
                // 依工單：原桌布路徑無法保存，就不得修改這顆螢幕。
                item["skipped"] = true
                item["skipReason"] = "無法取得原本桌布路徑，依規定不修改此螢幕。"
                anySkipped = true
                results.append(item)
                continue
            }
            item["skipped"] = false
            item["originalWallpaper"] = original.path
            item["originalDesktopOptions"] = DesktopController.describe(originalOptions)
            item["testImage"] = imageURL.path

            // 系統內建／動態桌布在 macOS 上回報的是 DefaultDesktop.heic 一類的路徑，
            // 畫面內容其實不是那張圖。本工具不擷取畫面，無法用像素確認，
            // 只能保守跳過（要硬做請加 --force，且結束後畫面不一定等於原本）。
            if DesktopController.isSystemDesktop(original) && !force {
                item["skipped"] = true
                item["skipReason"] = "系統／動態桌布（\(original.lastPathComponent)）無法用路徑確認畫面內容，依規定不修改此螢幕。要硬做請加 --force。"
                anySkipped = true
                results.append(item)
                continue
            }
            if DesktopController.isSystemDesktop(original) {
                item["forcedDespiteSystemDesktop"] = true
                item["warning"] = "原本桌布是系統／動態桌布：結束後這顆螢幕會停在 \(original.lastPathComponent)，不一定等於原本那張。"
            }

            if dryRun {
                item["dryRun"] = true
                item["wouldApply"] = true
                results.append(item)
                continue
            }

            anyModified = true

            // 1) 設成測試圖
            var appliedOK = false
            do {
                let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true
                ]
                try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: options)
                appliedOK = true
            } catch {
                item["applyError"] = error.localizedDescription
                anyFailed = true
            }
            if appliedOK {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let readback = NSWorkspace.shared.desktopImageURL(for: screen)
                item["readbackAfterApply"] = readback?.path ?? NSNull()
                item["readbackMatched"] = (readback?.standardizedFileURL == imageURL.standardizedFileURL)
                if item["readbackMatched"] as? Bool != true { anyFailed = true }
            }

            // 2) 恢復原圖（用原本的縮放／裁切設定，不要改掉使用者原本的選擇）
            do {
                // 空字典＝沒有額外選項，系統用自己的預設。
                try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: originalOptions)
                try? await Task.sleep(nanoseconds: 500_000_000)
                let restored = NSWorkspace.shared.desktopImageURL(for: screen)
                item["readbackAfterRestore"] = restored?.path ?? NSNull()
                item["restoreMatched"] = (restored?.standardizedFileURL == original.standardizedFileURL)
                if item["restoreMatched"] as? Bool != true { anyFailed = true }
            } catch {
                item["restoreError"] = error.localizedDescription
                anyFailed = true
            }
            results.append(item)
        }

        emit([
            "mode": "desktop-smoke",
            "image": imageURL.path,
            "dryRun": dryRun,
            "forced": force,
            "anyModified": anyModified,
            "anySkipped": anySkipped,
            "note": "僅作用於目前的 Space；不宣稱已套用到所有 Space。驗證只做 NSWorkspace 路徑讀回（沒有擷取畫面，沒有像素級證據）。",
            "displays": results
        ])
        return anyFailed ? 1 : 0
    }
}
