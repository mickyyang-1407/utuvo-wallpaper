import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var showGuide = UserDefaults.standard.bool(forKey: "UTUVOOpenGuide")
    @State private var language = AppLanguage.current()
    @State private var frequency = Preferences().rotationFrequency
    @State private var timing = DynamicTiming.load() == .solar ? DynamicTiming.solar : .fixed
    @StateObject private var location = LocationFetcher()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("globe", Color(hex: 0x0A84FF)) {
                        Picker(selection: Binding(get: { language }, set: { language = $0; AppLanguage.apply($0) })) {
                            ForEach(AppLanguage.allCases) { Text(verbatim: $0.displayName).tag($0) }
                        } label: {
                            Text(verbatim: "語言 Language")
                        }
                    }
                } footer: {
                    if AppLanguage.needsRelaunch(selected: language) {
                        Text(L("關閉並重新開啟 App 後套用新語言。"))
                    }
                }

                Section {
                    row("key.fill", TileStyle.all.color) {
                        Text(L("OpenAI API key"))
                        Spacer()
                        Pill(text: model.keyStored ? L("已儲存") : model.keyFromEnvironment ? L("使用環境變數") : L("未設定"),
                             color: model.keyStored || model.keyFromEnvironment ? Palette.green : Color(hex: 0x8E8E93), size: 12)
                    }
                    SecureField(model.keyStored ? L("貼上新的 key 以替換") : L("貼上 OpenAI API key"), text: $keyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .listRowBackground(Palette.cardFill)
                    HStack {
                        if model.keyStored {
                            Button(L("移除"), role: .destructive) { model.removeKey() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        Spacer()
                        Button(model.keyStored ? L("替換") : L("儲存")) {
                            keyError = model.saveKey(keyInput)
                            if keyError == nil { keyInput = "" }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(keyInput.isEmpty)
                    }
                    .listRowBackground(Palette.cardFill)
                    if let keyError {
                        Text(keyError).font(.footnote).foregroundStyle(Palette.orange).listRowBackground(Palette.cardFill)
                    }
                } footer: {
                    Text(L("key 只存在這支 iPhone 的鑰匙圈，存好後不會再顯示。生圖費用由你的 OpenAI 帳號計費。"))
                }

                Section {
                    row("sparkles", Palette.green) {
                        Toggle(L("每日自動生成"), isOn: $model.dailyEnabled).tint(Palette.green)
                    }
                    row("paintpalette", Color(hex: 0xBF5AF2)) {
                        Text(L("分類"))
                        Spacer()
                        Menu {
                            Button(L("全部分類")) { model.dailyRecipe.styles = [] }
                            Divider()
                            ForEach(DailyRecipe.categories, id: \.self) { category in
                                Toggle(WallpaperCategory.title(category), isOn: Binding(
                                    get: { model.dailyRecipe.categories.contains(category) },
                                    set: { model.dailyRecipe.setCategory(category, on: $0) }))
                            }
                        } label: {
                            let selected = model.dailyRecipe.categories
                            Text(selected.isEmpty ? L("全部分類")
                                 : selected.count == 1 ? WallpaperCategory.title(selected[0]) : L("\(selected.count) 個分類"))
                        }
                    }
                    row("lightbulb", Color(hex: 0xFFD60A)) {
                        TextField(L("自己的 Prompt（選填）"), text: Binding(
                            get: { model.dailyRecipe.idea },
                            set: { model.dailyRecipe.idea = String($0.prefix(DailyRecipe.ideaLimit)) }),
                                  prompt: Text(L("例如：台北的老公寓陽台")), axis: .vertical)
                            .lineLimit(1...3)
                        InspirationButton {
                            model.dailyRecipe.idea = PromptInspiration.pick(categories: model.dailyRecipe.categories,
                                                                            current: model.dailyRecipe.idea, chinese: isChineseUI)
                        }
                    }
                    if let p = model.dailyProgress {
                        row("calendar", Color(hex: 0x0A84FF)) {
                            Text(L("今天"))
                            Spacer()
                            Text(L("\(p.done)／\(p.total) 張")).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    row(TileStyle.favorites.symbol, TileStyle.favorites.color) {
                        Toggle(L("只輪換收藏"), isOn: $model.favoritesOnly).tint(Palette.green)
                    }
                    row("arrow.triangle.2.circlepath", Color(hex: 0x30B0C7)) {
                        Picker(L("換圖頻率"), selection: Binding(get: { frequency }, set: {
                            frequency = $0; Preferences().rotationFrequency = $0 })) {
                            ForEach(RotationFrequency.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    row("sun.horizon", Color(hex: 0xFF9F0A)) {
                        Picker(L("日夜切換"), selection: Binding(get: { timing }, set: {
                            timing = $0; UserDefaults.standard.set($0.rawValue, forKey: DynamicTiming.defaultsKey)
                            if $0 == .solar && Coordinate.load().fromTimeZone { location.fetch() } })) {
                            Text(L("固定時間")).tag(DynamicTiming.fixed)
                            Text(L("依日出日落")).tag(DynamicTiming.solar)
                        }
                    }
                    if timing == .solar {
                        row("location.fill", Color(hex: 0x0A84FF)) {
                            Text(locationText).foregroundStyle(.secondary).font(.subheadline)
                            Spacer()
                            Button(L("使用目前位置")) { location.fetch() }
                                .disabled(location.status == .locating)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("每天最多一批 10 張，每天換主題、配色、光線與構圖；寫了自己的 Prompt 就每張都畫它，用選的分類輪流表現。打開 App 時檢查，系統也可能在夜間補做；不保證準時。沒有收藏時會改用全部桌布。"))
                        Text(L("換圖頻率決定捷徑「取得目前桌布」多久換一張。"))
                        if timing == .solar {
                            let schedule = DynamicSchedule.load()
                            let _ = location.status
                            Text(L("今天：清晨 \(schedule.startTime(of: .dawn))、白天 \(schedule.startTime(of: .day))、黃昏 \(schedule.startTime(of: .dusk))、夜晚 \(schedule.startTime(of: .night))"))
                                .monospacedDigit()
                        }
                    }
                }

                Section {
                    Button { showGuide = true } label: {
                        row("wand.and.stars", Color(hex: 0x5E5CE6)) {
                            Text(L("捷徑自動化設定指南")).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Palette.cardFill)
                } footer: {
                    Text(L("iOS 不允許 App 自己換桌布，要透過「捷徑」App 的個人自動化。"))
                }

                Section {
                    row("internaldrive.fill", TileStyle.settings.color) {
                        Text(L("儲存空間"))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(model.usedBytes), countStyle: .file))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }

                Section {
                    Link(destination: URL(string: "https://utuvo.app")!) {
                        HStack { Spacer(); Text(verbatim: "utuvo.app").foregroundStyle(Palette.accent); Spacer() }
                    }
                    .listRowBackground(Palette.cardFill)
                } footer: {
                    Text(verbatim: "UTUVO Wallpaper \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CanvasBackground())
            .navigationTitle(L("設定"))
            .navigationDestination(isPresented: $showGuide) { ShortcutsGuideView() }
            .onAppear { model.reload(); location.refreshIfAuthorized() }
        }
    }

    private var locationText: String {
        switch location.status {
        case .locating: return L("正在取得位置…")
        case .denied: return Coordinate.load().fromTimeZone ? L("沒有位置權限，改用時區推估") : L("沒有位置權限，沿用上次的位置")
        case .failed: return Coordinate.load().fromTimeZone ? L("取不到位置，改用時區推估") : L("取不到新位置，沿用上次的位置")
        default: return Coordinate.load().fromTimeZone ? L("依時區推估位置") : L("使用你的位置")
        }
    }

    private func row<Content: View>(_ symbol: String, _ color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: color)
            content()
        }
        .listRowBackground(Palette.cardFill)
    }
}

struct ShortcutsGuideView: View {
    @Environment(\.openURL) private var openURL

    private var steps: [String] {
        [L("打開「捷徑」App，切到下方的「自動化」。"),
         L("點右上角「＋」，選「特定時間」，設定想換桌布的時間（例如每天 07:00），選「每天」，再選「立即執行」。"),
         L("點「新增動作」，搜尋「UTUVO Wallpaper」，加入「取得目前桌布」。"),
         L("再搜尋「設定背景圖片」（系統內建動作），把上一步的圖片接進去，選要套用的背景與「主畫面／鎖定畫面」。"),
         L("關掉「顯示預覽」與「裁切至主體」，完成。"),
         L("想每次都換新的一張，可以把第 3 步改成「下一張桌布」，或在設定把「換圖頻率」改成「每次執行都換」。"),
         DynamicTiming.load() == .solar
            ? L("日夜模式（依日出日落）：建四個自動化，觸發選「日出」或「日落」——日出前 30 分鐘、日出後 1 小時、日落前 1 小時、日落後 30 分鐘。")
            : L("日夜模式（固定時間）：在 06:00、09:00、18:00、21:00 各建一個自動化。")]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: L("捷徑設定指南"), pill: L("\(steps.count) 步"), color: Color(hex: 0x5E5CE6))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0x5E5CE6)))
                            Text(step).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        if index < steps.count - 1 { Divider().padding(.leading, 42) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .card()
                HStack(alignment: .top, spacing: 12) {
                    IconTile(symbol: "bolt.fill", color: Palette.green, size: 30)
                    Text(L("「取得目前桌布」很快、不連網也不生圖：只從已經存在 iPhone 裡的桌布挑一張。"))
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.green.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.green.opacity(0.30), lineWidth: 1))
                Button {
                    openURL(URL(string: "shortcuts://")!)
                } label: {
                    Label(L("打開捷徑"), systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(16)
        }
        .background(CanvasBackground())
        .navigationTitle(L("捷徑設定指南"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}
