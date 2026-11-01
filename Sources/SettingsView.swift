import SwiftUI
import AppKit

extension Notification.Name {
    static let wallpaperOpenSettings = Notification.Name("com.utuvo.wallpaper-lab.open-settings")
}

struct WallpaperSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftKey = ""
    @State private var source = ""
    @State private var hasSavedKey = false
    @State private var message: String?
    @State private var error: String?
    @State private var confirmRemoval = false
    @State private var backgroundEnabled = BackgroundService.isEnabled()
    @State private var backgroundLoaded = false
    @State private var backgroundSnapshot: BackgroundSnapshot?
    private let keychain = KeychainCredentialStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("UTUVO Wallpaper 設定").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            Form {
                Section("生圖服務") {
                    LabeledContent("方式", value: "OpenAI Images API")
                    LabeledContent("模型", value: OpenAIImageProvider.model)
                    Text("自動生成使用 API 帳戶額度。已啟用的訂閱附贈 API 額度也能使用相同接口；ChatGPT 訂閱登入目前不支援第三方自動生圖。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("訂閱附贈 API 額度說明", destination: URL(string: "https://developers.openai.com/api/docs/guides/chatgpt-api-credits")!)
                }
                Section("API key") {
                    LabeledContent("目前來源", value: source)
                    SecureField(hasSavedKey ? "輸入新的 API key 以替換" : "輸入自己的 OpenAI API key", text: $draftKey)
                        .accessibilityLabel("OpenAI API key")
                    HStack {
                        Button("儲存到鑰匙圈") { saveKey() }
                            .buttonStyle(.borderedProminent)
                            .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("移除已儲存的 key", role: .destructive) { confirmRemoval = true }
                            .disabled(!hasSavedKey)
                    }
                    Text("金鑰保留在這台 Mac 的鑰匙圈，不隨程式碼分享。儲存只在本機進行，不會發送生圖請求，也不代表已驗證 API 權限或剩餘額度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("每日桌布") {
                    Toggle("登入後在背景自動生成與輪換", isOn: Binding(
                        get: { backgroundEnabled }, set: { setBackground($0) }))
                    Text("每天產生 10 種風格的 6K 桌布，完成後每小時輪換。使用 API 額度，關閉視窗後仍會執行。Mac 需登入且醒著；喚醒後會補檢查當日排程。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("6K 為 6144 × 3456 重採樣，原生 3840 × 2160 PNG 另存。每天最多嘗試一批，失敗不會無限重試。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("背景服務", value: backgroundLoaded ? L("已載入") : L("未載入"))
                    if let snapshot = backgroundSnapshot {
                        LabeledContent("狀態", value: BackgroundSnapshot.stageTitle(snapshot.stage))
                        if !snapshot.progress.isEmpty { Text(snapshot.progress).font(.caption) }
                        if let date = snapshot.lastBatchDate {
                            Text("上次生成：\(date.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.lastBatchCount) 張")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let issue = snapshot.error {
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        } else if !snapshot.message.isEmpty {
                            Text(snapshot.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("圖片儲存位置") {
                    Text(dataPath).font(.caption).textSelection(.enabled)
                    Text("原圖在 originals，桌布在 wallpapers。移動 App 不會移動或刪除你的圖庫。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("開啟圖片資料夾") { openDataFolder() }
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            } else if let message {
                Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
        .frame(width: 590, height: 730)
        .background(WallpaperPalette.panel)
        .tint(WallpaperPalette.accent)
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in refreshBackground() }
        .onDisappear { draftKey = "" }
        .confirmationDialog("移除 UTUVO Wallpaper 儲存的 API key？", isPresented: $confirmRemoval) {
            Button("移除", role: .destructive) {
                do {
                    try keychain.remove()
                    draftKey = ""
                    message = L("已移除鑰匙圈中的 key。環境變數與既有 .env 不會被刪除。")
                    error = nil
                    refresh()
                } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("這只移除本 App 的鑰匙圈項目。你之後可以重新輸入。")
        }
    }

    private var dataPath: String {
        let path = LabPaths.deliveryRoot.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    private func refresh() {
        refreshBackground()
        source = CredentialStore.sourceDescription()
        do { hasSavedKey = try keychain.exists() }
        catch { self.error = error.localizedDescription }
    }

    private func refreshBackground() {
        backgroundEnabled = BackgroundService.isEnabled()
        backgroundLoaded = BackgroundService.isLoaded()
        backgroundSnapshot = BackgroundSnapshot.load()
    }

    private func setBackground(_ enabled: Bool) {
        do {
            if enabled {
                guard CredentialStore.load() != nil else {
                    error = GenerationError.missingCredential.localizedDescription
                    return
                }
                guard let executable = Bundle.main.executableURL else { return }
                // Establish background ownership first, so the GUI cannot claim
                // today's paid batch while the LaunchAgent is being installed.
                try BackgroundService.enable(executableURL: executable)
                model.setDailyMode(.ten)
                if !model.isDynamicActive { model.setRotationMode(.hourly) }
                UserDefaults.standard.synchronize()
                message = L("已啟用。第一輪會在一分鐘內開始，可以關閉視窗。")
            } else {
                try BackgroundService.disable()
                model.setDailyMode(.off)
                model.setRotationMode(.off)
                message = L("已停止背景自動生成與輪換。")
            }
            model.refreshAutomationOwnership()
            error = nil
        } catch { self.error = error.localizedDescription }
        refreshBackground()
    }

    private func saveKey() {
        do {
            try keychain.save(draftKey)
            draftKey = ""
            error = nil
            message = L("已儲存到 Mac 鑰匙圈，下一次生成會使用這個 key。")
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func openDataFolder() {
        do {
            try FileManager.default.createDirectory(at: LabPaths.wallpapersDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(LabPaths.wallpapersDir)
        } catch { self.error = L("資料夾無法開啟，請確認儲存位置可以寫入。") }
    }
}
