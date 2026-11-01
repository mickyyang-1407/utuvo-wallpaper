import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum WallpaperPalette {
    static let accent = Color(red: 166.0 / 255, green: 100.0 / 255, blue: 69.0 / 255)
    static let canvas = surface(light: 0xFAF7F1, dark: 0x292521)
    static let panel = surface(light: 0xF2ECE3, dark: 0x302A25)

    private static func surface(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb: UInt32 = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            let red = CGFloat((rgb >> 16) & 255) / 255.0
            let green = CGFloat((rgb >> 8) & 255) / 255.0
            let blue = CGFloat(rgb & 255) / 255.0
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        })
    }
}

private enum WallpaperSection: String, CaseIterable, Identifiable {
    case all, favorites, dynamic
    var id: Self { self }
    var title: String {
        switch self {
        case .all: return L("所有桌布")
        case .favorites: return L("收藏")
        case .dynamic: return L("動態桌布")
        }
    }
    var symbol: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .favorites: return "heart"
        case .dynamic: return "sun.max"
        }
    }
}

private enum SidebarSelection: Hashable {
    case section(WallpaperSection)
    case category(String)

    var title: String {
        switch self {
        case .section(let section): return section.title
        case .category(let name): return categoryTitle(name)
        }
    }
}

/// 分類 key 是範本的繁中名稱；顯示時才翻譯。
func categoryTitle(_ name: String) -> String {
    switch name {
    case "自然": return L("自然")
    case "極簡": return L("極簡")
    case "抽象": return L("抽象")
    case "插畫": return L("插畫")
    case "宇宙": return L("宇宙")
    case "水彩": return L("水彩")
    case "建築": return L("建築")
    case "動畫": return L("動畫")
    case "其他": return L("其他")
    default: return name
    }
}

private func categorySymbol(_ name: String) -> String {
    switch name {
    case "自然": return "leaf"
    case "極簡": return "square"
    case "抽象": return "scribble.variable"
    case "插畫": return "paintbrush.pointed"
    case "宇宙": return "sparkles"
    case "水彩": return "paintpalette"
    case "建築": return "building.columns"
    case "動畫": return "film"
    default: return "photo"
    }
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var section: SidebarSelection? = .section(.all)
    @State private var search = ""
    @State private var newestFirst = false
    @State private var showInspector = true
    @State private var showGeneration = false
    @State private var showSchedule = false
    @State private var showSettings = false
    @State private var scenePrompt = L("山間湖畔的一間木屋、遠山、樹林與平靜倒影，固定視角，溫暖寫實攝影")
    @State private var previewPhase: DynamicPhase?
    @State private var displays = DesktopController.snapshots()

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 440), spacing: 20)]
    private var isDynamic: Bool { section == .section(.dynamic) }
    private var isFavorites: Bool { section == .section(.favorites) }
    private var selectedCategory: String? {
        if case .category(let name) = section { return name }
        return nil
    }
    private var visibleCategories: [String] {
        let present = Set(model.wallpapers.map(\.category))
        return WallpaperLibrary.categoryOrder.filter { present.contains($0) }
    }

    private var visibleWallpapers: [Wallpaper] {
        let result = model.wallpapers.filter {
            (!isFavorites || model.favoriteIDs.contains($0.id)) &&
            (selectedCategory == nil || $0.category == selectedCategory) &&
            (search.isEmpty || displayTitle($0).localizedCaseInsensitiveContains(search) ||
             $0.name.localizedCaseInsensitiveContains(search))
        }
        guard newestFirst else { return result }
        let dated: [(wallpaper: Wallpaper, date: Date)] = result.map { item in
            let values = try? item.url.resourceValues(forKeys: [.creationDateKey])
            return (item, values?.creationDate ?? Date.distantPast)
        }
        return dated.sorted { left, right in
            left.date == right.date ? left.wallpaper.name < right.wallpaper.name : left.date > right.date
        }.map { $0.wallpaper }
    }

    private var inspected: Wallpaper? {
        visibleWallpapers.first { $0.id == model.selectedID } ?? visibleWallpapers.first
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $section) {
                    Section("圖庫") {
                        ForEach(WallpaperSection.allCases) { destination in
                            Label(destination.title, systemImage: destination.symbol)
                                .listItemTint(.fixed(WallpaperPalette.accent))
                                .badge(count(for: destination)).tag(SidebarSelection.section(destination))
                        }
                    }
                    if !visibleCategories.isEmpty {
                        Section("分類") {
                            ForEach(visibleCategories, id: \.self) { name in
                                Label(categoryTitle(name), systemImage: categorySymbol(name))
                                    .listItemTint(.fixed(WallpaperPalette.accent))
                                    .badge(model.wallpapers.filter { $0.category == name }.count)
                                    .tag(SidebarSelection.category(name))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                Divider()
                HStack {
                    Button { model.openWallpaperFolder() } label: {
                        Image(systemName: "folder")
                    }
                    .help("開啟桌布資料夾").accessibilityLabel("開啟桌布資料夾")
                    Spacer()
                    Text("\(model.wallpapers.count) 張桌布").foregroundStyle(.secondary)
                    Spacer()
                    Link("utuvo.app", destination: URL(string: "https://utuvo.app")!)
                        .foregroundStyle(WallpaperPalette.accent)
                }
                .buttonStyle(.borderless).font(.caption).padding(12)
            }
            .background(WallpaperPalette.panel)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage { errorBanner(error) }
                if isDynamic { dynamicGallery } else { stillGallery }
                statusBar
            }
            .background(WallpaperPalette.canvas)
            .navigationTitle(section?.title ?? L("所有桌布"))
            .searchable(text: $search, placement: .toolbar, prompt: "搜尋桌布")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showSettings = true } label: { Label("設定", systemImage: "gearshape") }
                        .help("API key 與圖片儲存位置")
                    Button { showGeneration.toggle() } label: {
                        Label("產生桌布", systemImage: "wand.and.rays")
                    }
                    .help("產生桌布").popover(isPresented: $showGeneration) { generationControls }
                    Button { showSchedule.toggle() } label: {
                        Label("輪換與每日生成", systemImage: "clock")
                    }
                    .help("輪換與每日生成").popover(isPresented: $showSchedule) { scheduleControls }
                    Menu {
                        Button("重新讀取圖庫", systemImage: "arrow.clockwise") { model.reload() }
                        Button("開啟桌布資料夾", systemImage: "folder") { model.openWallpaperFolder() }
                        if !isDynamic {
                            Divider()
                            Picker("排序", selection: $newestFirst) {
                                Text("依檔案名稱").tag(false)
                                Text("最新加入優先").tag(true)
                            }
                        }
                    } label: { Label("更多", systemImage: "ellipsis.circle") }
                    .help("圖庫選項")
                    Button { showInspector.toggle() } label: {
                        Label("顯示檢視器", systemImage: "sidebar.right")
                    }
                    .help("顯示或隱藏檢視器")
                }
            }
            .inspector(isPresented: $showInspector) { inspector }
            .inspectorColumnWidth(min: 270, ideal: 290, max: 340)
        }
        .id(model.dynamicRevision)
        .navigationSplitViewStyle(.balanced)
        .tint(WallpaperPalette.accent)
        .accentColor(WallpaperPalette.accent)
        .frame(minWidth: 1000, minHeight: 660)
        .sheet(isPresented: $showSettings) { WallpaperSettingsView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperOpenSettings)) { _ in showSettings = true }
        .onChange(of: section) { _, _ in search = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DesktopController.snapshots()
        }
    }

    private func count(for section: WallpaperSection) -> Int {
        switch section {
        case .all: return model.wallpapers.count
        case .favorites: return model.wallpapers.filter { model.favoriteIDs.contains($0.id) }.count
        case .dynamic: return DynamicScene.isReady ? 1 : 0
        }
    }

    private var stillGallery: some View {
        Group {
            if visibleWallpapers.isEmpty {
                ContentUnavailableView(search.isEmpty ? "尚無桌布" : "找不到桌布",
                    systemImage: isFavorites ? "heart" : "photo.on.rectangle",
                    description: Text(isFavorites && search.isEmpty
                        ? "選取圖片，按愛心加入收藏。" : "試試其他搜尋文字，或產生新的桌布。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(visibleWallpapers) { wallpaper in
                            Button { model.select(wallpaper) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    thumbnail(wallpaper.url, selected: inspected?.id == wallpaper.id)
                                    HStack(spacing: 6) {
                                        Text(displayTitle(wallpaper)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if model.favoriteIDs.contains(wallpaper.id) {
                                            Image(systemName: "heart.fill").foregroundStyle(.secondary)
                                        }
                                    }
                                    .font(.callout)
                                    Text(wallpaper.pixelText).font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityLabel("選取 \(displayTitle(wallpaper))")
                            .contextMenu {
                                Button("設為桌布") { Task { await model.apply(wallpaper) } }
                                    .disabled(model.isApplying)
                                Button(model.favoriteIDs.contains(wallpaper.id) ? "取消收藏" : "加入收藏") {
                                    model.toggleFavorite(wallpaper)
                                }
                                Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([wallpaper.url]) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var dynamicGallery: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let current = previewPhase ?? DynamicPhase.current(at: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("生成自己的日夜桌布").font(.headline)
                        TextField("描述同一個場景", text: $scenePrompt)
                            .textFieldStyle(.roundedBorder)
                        Text("先生成白天，再參考同一張原圖編修清晨、黃昏、夜晚；原圖保留，成品為 6144 × 3456 重採樣。")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.isGenerating {
                            HStack { ProgressView().controlSize(.small); Text(model.generationProgress); Button("取消生成") { model.cancelGeneration() } }
                        } else {
                            Button("生成四時段 6K") { model.startDynamicGeneration(prompt: scenePrompt) }
                                .buttonStyle(.borderedProminent)
                                .disabled(scenePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DynamicScene.title).font(.headline)
                            Text("4 個時段 · \(DynamicScene.resolution)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("預覽", selection: $previewPhase) {
                            Text("目前時間").tag(Optional<DynamicPhase>.none)
                            ForEach(DynamicPhase.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        .frame(width: 150)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(DynamicPhase.allCases.filter {
                            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
                            DynamicScene.title.localizedCaseInsensitiveContains(search)
                        }) { phase in
                            Button { previewPhase = phase } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    thumbnail(DynamicScene.imageURL(phase), selected: current == phase)
                                    HStack {
                                        Text(phase.title)
                                        Spacer()
                                        Text(phase.time).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                }
                            }
                            .buttonStyle(.plain).accessibilityLabel("預覽\(phase.title) \(phase.time)")
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            if isDynamic {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let phase = previewPhase ?? DynamicPhase.current(at: context.date)
                    VStack(alignment: .leading, spacing: 10) {
                        thumbnail(DynamicScene.imageURL(phase), selected: false)
                        Text(DynamicScene.title).font(.headline)
                        Text("\(phase.title) · \(phase.time) 起").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
                Form {
                    Section("圖片") {
                        LabeledContent("解析度", value: DynamicScene.resolution)
                        LabeledContent("格式", value: L("HEIC · 4 個時段"))
                        LabeledContent("切換方式", value: L("App 背景時段排程"))
                        Text(model.isDynamicActive ? "日夜模式已啟用，一般輪換暫停" : "設定後由背景自動切換時段").font(.caption)
                    }
                    Section("桌面") { displayPicker }
                }
                .formStyle(.grouped)
                VStack(spacing: 10) {
                    Button("匯出 HEIC…", systemImage: "square.and.arrow.up") { exportDynamic() }
                        .disabled(!DynamicScene.hasExport)
                    applyButton.disabled(!DynamicScene.hasExport)
                }
                .padding(16)
            } else if let wallpaper = inspected {
                VStack(alignment: .leading, spacing: 12) {
                    thumbnail(wallpaper.url, selected: false)
                    HStack {
                        Text(displayTitle(wallpaper)).font(.headline)
                        Spacer()
                        Button { model.toggleFavorite(wallpaper) } label: {
                            Image(systemName: model.favoriteIDs.contains(wallpaper.id) ? "heart.fill" : "heart")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(model.favoriteIDs.contains(wallpaper.id) ? "取消收藏" : "加入收藏")
                    }
                }
                .padding(16)
                Form {
                    Section("圖片") {
                        LabeledContent("解析度", value: wallpaper.pixelText)
                        LabeledContent("檔案大小", value: wallpaper.sizeText)
                        LabeledContent("影像來源", value: wallpaper.origin.label)
                        LabeledContent("檔案") {
                            Text(wallpaper.name).lineLimit(3).textSelection(.enabled)
                        }
                    }
                    Section("桌面") { displayPicker }
                }
                .formStyle(.grouped)
                HStack {
                    Button { browse(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("上一張")
                    Button { browse(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("下一張")
                    Spacer()
                    applyButton
                }
                .padding(16)
            } else {
                ContentUnavailableView("選取桌布", systemImage: "photo")
            }
        }
        .background(WallpaperPalette.panel)
    }

    private var displayPicker: some View {
        Picker("套用到", selection: $model.targetDisplayID) {
            Text("所有螢幕").tag(Optional<UInt32>.none)
            ForEach(displays, id: \.displayID) { display in
                Text(display.name).tag(Optional(display.displayID))
            }
            if let id = model.targetDisplayID, !displays.contains(where: { $0.displayID == id }) {
                Text("已中斷連線").tag(Optional(id))
            }
        }
        .disabled(model.isApplying)
    }

    private var applyButton: some View {
        Button(model.isApplying ? "套用中…" : "設為桌布") {
            if isDynamic {
                Task { await model.activateDynamic() }
            } else if let wallpaper = inspected {
                Task { await model.apply(wallpaper) }
            }
        }
        .buttonStyle(.borderedProminent).disabled(model.isApplying)
    }

    private func thumbnail(_ url: URL, selected: Bool) -> some View {
        GeometryReader { geometry in
            ZStack {
                WallpaperPalette.panel
                if let cg = WallpaperLibrary.thumbnail(from: url, maxPixel: 900) {
                    Image(nsImage: NSImage(cgImage: cg, size: .zero))
                        .resizable().scaledToFit()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? WallpaperPalette.accent : .clear, lineWidth: 2))
        }
        .aspectRatio(16.0 / 9, contentMode: .fit)
    }

    private func browse(_ delta: Int) {
        let manualRotation = model.rotationMode == .manual
        let pool = manualRotation && model.rotationFavoritesOnly
            ? visibleWallpapers.filter { model.favoriteIDs.contains($0.id) } : visibleWallpapers
        guard !pool.isEmpty else {
            if manualRotation && model.rotationFavoritesOnly {
                model.stopRotation()
                model.errorMessage = L("目前範圍沒有可輪換的收藏，輪換已停止。")
            }
            return
        }
        let index = pool.firstIndex { $0.id == inspected?.id } ?? 0
        let next = pool[(index + delta + pool.count) % pool.count]
        model.select(next)
        if manualRotation { Task { await model.apply(next) } }
    }

    private var generationControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("產生桌布").font(.headline)
            Picker("張數", selection: $model.generateCount) {
                Text("1 張").tag(1); Text("5 張").tag(5); Text("10 張").tag(10)
            }
            Text("原生 3840 × 2160，另存 6144 × 3456 的 6K 重採樣版本。使用現有 API 憑證。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("10 張會使用 10 種不同風格／主題。").font(.caption).foregroundStyle(.secondary)
            if model.isGenerating {
                ProgressView().controlSize(.small)
                Text(model.generationProgress).font(.callout)
                Button("取消生成") { model.cancelGeneration() }
            } else {
                Button("產生 \(model.generateCount) 張") { model.startGeneration(count: model.generateCount) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 300)
    }

    private var scheduleControls: some View {
        Form {
            Section("桌布輪換") {
                Picker("頻率", selection: Binding(get: { model.rotationMode }, set: { model.setRotationMode($0) })) {
                    ForEach(RotationController.Mode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("僅輪換收藏", isOn: $model.rotationFavoritesOnly)
            }
            Section("每日生成") {
                Picker("張數", selection: Binding(get: { model.dailyMode }, set: { model.setDailyMode($0) })) {
                    ForEach(DailyScheduler.Mode.allCases) { Text($0.title).tag($0) }
                }
                Text("設定會保留。每天最多一批，使用 API 額度。要在關閉視窗後繼續，請到設定啟用背景服務；背景只輪換 6K 成品。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("背景服務設定") { showSchedule = false; showSettings = true }
            }
        }
        .formStyle(.grouped).frame(width: 380, height: 350)
    }

    private var statusBar: some View {
        HStack {
            if model.isGenerating { ProgressView().controlSize(.mini) }
            Text(model.isGenerating ? model.generationProgress : model.statusMessage)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(isDynamic ? "4 個時段" : "\(visibleWallpapers.count) 張")
            if model.dailyMode != .off { Text(model.dailyMode.title) }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .top) { Divider() }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
            Spacer()
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("關閉錯誤訊息")
        }
        .font(.callout).padding(12).background(Color(nsColor: .controlBackgroundColor))
    }

    private func displayTitle(_ wallpaper: Wallpaper) -> String {
        if wallpaper.name.hasPrefix("abstract-flow") { return L("流光") }
        if wallpaper.name.hasPrefix("alpine-dawn") { return L("湖畔晨光") }
        if wallpaper.name.hasPrefix("paper-landscape") { return L("紙上山丘") }
        if wallpaper.name.hasPrefix("nature-dawn") { return L("破曉山稜") }
        return wallpaper.url.deletingPathExtension().lastPathComponent
    }

    private func exportDynamic() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.heic]
        panel.nameFieldStringValue = DynamicScene.title + ".heic"
        panel.canCreateDirectories = true
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                if url.standardizedFileURL != DynamicScene.heicURL.standardizedFileURL {
                    try Data(contentsOf: DynamicScene.heicURL).write(to: url, options: .atomic)
                }
                model.statusMessage = L("已匯出：\(url.lastPathComponent)")
            } catch { model.errorMessage = L("無法匯出 HEIC，請確認目的資料夾可寫入。") }
        }
    }
}
