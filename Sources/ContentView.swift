import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
        case .favorites: return "heart.fill"
        case .dynamic: return "sun.max.fill"
        }
    }
    var color: Color {
        switch self {
        case .all: return WallpaperPalette.hex(0x0A84FF)
        case .favorites: return WallpaperPalette.hex(0xFF375F)
        case .dynamic: return WallpaperPalette.hex(0xFF9F0A)
        }
    }
}

private enum SidebarSelection: Hashable {
    case section(WallpaperSection)
    case category(String)
    case tag(String)
    case resolution(ResolutionTier)

    var title: String {
        switch self {
        case .section(let section): return section.title
        case .category(let name): return categoryTitle(name)
        case .tag(let name): return name
        case .resolution(let tier): return tier.title
        }
    }
}

/// 新增／改名標籤的表單內容。
private struct TagDraft: Identifiable {
    var original: String?
    var name: String
    var color: String
    var id: String { original ?? "＋" }
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
    case "純色": return L("純色")
    case "漸層": return L("漸層")
    case "深色": return L("深色")
    case "幾何": return L("幾何")
    case "城市": return L("城市")
    case "動物": return L("動物")
    case "3D": return L("3D")
    case "其他": return L("其他")
    default: return name
    }
}

struct ContentView: View {
    @State private var model: AppModel

    init(model: AppModel) { _model = State(initialValue: model) }
    @State private var section: SidebarSelection? = .section(.all)
    @State private var search = ""
    @State private var newestFirst = false
    @State private var showInspector = true
    /// 大圖預覽中的桌布 id（nil＝沒開）。
    @State private var previewID: String?
    @State private var showGeneration = false
    @State private var showSchedule = false
    @State private var showSettings = false
    @State private var scenePrompt = ""
    @State private var previewPhase: DynamicPhase?
    @State private var hoverPhase: DynamicPhase?
    @State private var scenes: [DynamicSceneEntry] = []
    @State private var sceneID: String?
    @State private var displays = DesktopController.snapshots()
    /// 顯示名稱與建立日期：圖庫清單改變時才算一次，render 期間只查表。
    @State private var index = WallpaperIndex()
    @State private var tagDraft: TagDraft?
    @State private var pendingTrash: Set<String>?
    @State private var keyMonitor: Any?
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 440), spacing: 18)]
    /// 浮動操作列的高度＋留白；內容底部要讓出這段距離。
    /// 浮動列高約 52＋離底 18＋留白 24（工單：≥ 浮動列高度＋24），捲到底時最後一列完整露出。
    private let floatingClearance: CGFloat = 120
    private var isDynamic: Bool { section == .section(.dynamic) }
    private var isFavorites: Bool { section == .section(.favorites) }
    private var isOverview: Bool { section == .section(.all) || section == nil }
    private var selectedCategory: String? {
        if case .category(let name) = section { return name }
        return nil
    }
    private var selectedTag: String? {
        if case .tag(let name) = section { return name }
        return nil
    }
    private var selectedTier: ResolutionTier? {
        if case .resolution(let tier) = section { return tier }
        return nil
    }
    private var resolutionTiers: [(ResolutionTier, Int)] {
        ResolutionTier.histogram(widths: model.wallpapers.map(\.pixelWidth))
    }
    /// 側欄分類：所有分類都列出來（還沒有圖的變淡、數字 0），「其他」只在有圖時出現。
    private var visibleCategories: [String] {
        let present = Set(model.wallpapers.map(\.category))
        return WallpaperLibrary.categoryOrder.filter { $0 != WallpaperLibrary.otherCategory || present.contains($0) }
    }

    private var visibleWallpapers: [Wallpaper] {
        let tagged = selectedTag.map { model.ids(withTag: $0) }
        let result = model.wallpapers.filter {
            (!isFavorites || model.favoriteIDs.contains($0.id)) &&
            (selectedCategory == nil || $0.category == selectedCategory) &&
            (tagged == nil || tagged!.contains($0.id)) &&
            (selectedTier == nil || ResolutionTier.tier(forWidth: $0.pixelWidth) == selectedTier) &&
            (search.isEmpty || displayTitle($0).localizedCaseInsensitiveContains(search) ||
             $0.name.localizedCaseInsensitiveContains(search))
        }
        guard newestFirst else { return result }
        let dated: [(wallpaper: Wallpaper, date: Date)] = result.map { item in
            (item, index.created[item.id] ?? Date.distantPast)
        }
        return dated.sorted { left, right in
            left.date == right.date ? left.wallpaper.name < right.wallpaper.name : left.date > right.date
        }.map { $0.wallpaper }
    }

    private var inspected: Wallpaper? {
        if model.selection.ids.isEmpty { return nil }
        return visibleWallpapers.first { $0.id == model.selection.primary } ?? visibleWallpapers.first { model.selection.ids.contains($0.id) }
    }

    /// 畫面上、且在選取集合內的圖（依畫面順序）。
    private var selectedVisible: [Wallpaper] {
        visibleWallpapers.filter { model.selection.ids.contains($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage, !isOverview { errorBanner(error) }
                ZStack(alignment: .bottom) {
                    if isDynamic { dynamicGallery } else { stillGallery }
                    floatingBar.padding(.bottom, 18)
                }
                statusBar
            }
            .overlay { if let id = previewID, let wallpaper = visibleWallpapers.first(where: { $0.id == id }) { previewOverlay(wallpaper) } }
            .background(CanvasBackground(backdrop: backdropImage))
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
        .onChange(of: model.dynamicRevision, initial: true) { _, _ in reloadScenes() }
        .onChange(of: model.wallpapers.map(\.id), initial: true) { _, _ in
            index = WallpaperIndex(library: model.wallpapers)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(WallpaperPalette.accent)
        .accentColor(WallpaperPalette.accent)
        .frame(minWidth: 1000, minHeight: 660)
        .sheet(isPresented: $showSettings) { WallpaperSettingsView(model: model) }
        .sheet(item: $tagDraft) { draft in
            TagEditor(draft: draft, existing: Set(model.tags.map(\.name))) { result in
                let saved: Bool
                if let original = result.original {
                    saved = model.editTags { store in
                        try store.renameTag(original, to: result.name)
                        try store.recolorTag(result.name.trimmingCharacters(in: .whitespacesAndNewlines), color: result.color)
                    }
                    if saved, section == .tag(original) {
                        section = .tag(result.name.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } else {
                    saved = model.editTags { try $0.addTag(name: result.name, color: result.color) }
                }
                if saved { tagDraft = nil }
            } onCancel: { tagDraft = nil }
        }
        // 自訂確認視窗：不透明底，文字與按鈕對比足夠（系統 alert 在 macOS 26 會透出背景圖）。
        .sheet(isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            TrashConfirmSheet(title: trashTitle) {
                if let ids = pendingTrash { model.trash(ids: ids, order: visibleWallpapers.map(\.id)) }
                pendingTrash = nil
            } onCancel: { pendingTrash = nil }
        }
        .onAppear { installKeyMonitor(); openScreenshotState() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperOpenSettings)) { _ in showSettings = true }
        .onChange(of: section) { _, _ in
            search = ""
            if isDynamic { reloadScenes() }
            syncSelectionToVisible()
        }
        .onChange(of: search) { _, _ in syncSelectionToVisible() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DesktopController.snapshots()
        }
    }

    // MARK: - 側欄

    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(WallpaperSection.allCases) { destination in
                        sidebarRow(.section(destination), title: destination.title, symbol: destination.symbol,
                                   color: destination.color, count: count(for: destination))
                    }
                } header: {
                    Text("圖庫").foregroundStyle(WallpaperPalette.secondaryText)
                }
                if !visibleCategories.isEmpty {
                    Section {
                        ForEach(visibleCategories, id: \.self) { name in
                            sidebarRow(.category(name), title: categoryTitle(name),
                                       symbol: WallpaperPalette.categorySymbol(name),
                                       color: WallpaperPalette.categoryColor(name),
                                       count: categoryCount(name))
                        }
                    } header: {
                        Text("分類").foregroundStyle(WallpaperPalette.secondaryText)
                    }
                }
                Section {
                    ForEach(model.tags) { tag in
                        sidebarRow(.tag(tag.name), title: tag.name, symbol: "", color: WallpaperPalette.muted(tag.color),
                                   count: model.tagCount(tag.name), dot: true)
                            .contextMenu { tagRowMenu(tag) }
                    }
                    if model.tags.isEmpty {
                        Text("按 ＋ 新增標籤")
                            .font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
                            .padding(.horizontal, 8)
                    }
                } header: {
                    HStack {
                        Text("標籤").foregroundStyle(WallpaperPalette.secondaryText)
                        Spacer()
                        Button { tagDraft = TagDraft(original: nil, name: "", color: TagStore.palette[model.tags.count % TagStore.palette.count]) } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("新增標籤").accessibilityLabel("新增標籤")
                    }
                }
                if !resolutionTiers.isEmpty {
                    Section {
                        ForEach(resolutionTiers, id: \.0) { tier, count in
                            sidebarRow(.resolution(tier), title: tier.title, symbol: "aspectratio.fill",
                                       color: WallpaperPalette.resolutionColor(tier), count: count,
                                       glass: WallpaperPalette.resolutionGlass(tier))
                        }
                    } header: {
                        Text("解析度").foregroundStyle(WallpaperPalette.secondaryText)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // 灰色選取比照參考圖：macOS 側欄 List 的系統選取不吃 .tint（實測仍是藍色），
            // 所以不用 List(selection:)，改由每列自己畫灰色選取底；藍色只留給主要動作。
            Divider()
            HStack {
                Button { model.openWallpaperFolder() } label: {
                    Image(systemName: "folder")
                }
                .help("開啟桌布資料夾").accessibilityLabel("開啟桌布資料夾")
                Spacer()
                Text("\(model.wallpapers.count) 張桌布").monospacedDigit().foregroundStyle(WallpaperPalette.secondaryText)
                Spacer()
                Link("utuvo.app", destination: URL(string: "https://utuvo.app")!)
                    .foregroundStyle(WallpaperPalette.accent)
            }
            .buttonStyle(.borderless).font(.caption).padding(12)
        }
        .panelBackground()
    }

    private func sidebarRow(_ target: SidebarSelection, title: String, symbol: String, color: Color,
                            count: Int, dot: Bool = false, glass: String? = nil) -> some View {
        let selected = section == target
        return Button { section = target } label: {
            HStack(spacing: 10) {
                if dot {
                    Circle().fill(color).frame(width: 10, height: 10).frame(width: 24, height: 24)
                } else {
                    IconTile(symbol: symbol, color: color, size: 24, glass: glass)
                }
                Text(title).lineLimit(1)
                    .fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: 4)
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.primary : WallpaperPalette.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .opacity(count == 0 && !selected ? 0.5 : 1)
            .modifier(SidebarSelectionBackground(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func count(for section: WallpaperSection) -> Int {
        switch section {
        case .all: return model.wallpapers.count
        case .favorites: return model.wallpapers.filter { model.favoriteIDs.contains($0.id) }.count
        case .dynamic: return scenes.count
        }
    }

    private func categoryCount(_ name: String) -> Int {
        model.wallpapers.filter { $0.category == name }.count
    }

    // MARK: - Overview 資料（全部來自真實模型與檔案）

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 今天新增：檔名含 `daily-<今天日期>`，或檔案建立日期是今天。
    private func isAddedToday(_ wallpaper: Wallpaper, now: Date) -> Bool {
        let today = Self.dayFormatter.string(from: now)
        if wallpaper.name.contains("daily-\(today)") { return true }
        guard let created = index.created[wallpaper.id] else { return false }
        return Calendar.current.isDate(created, inSameDayAs: now)
    }

    private struct CategoryShare: Identifiable {
        let name: String
        let total: Int
        let today: Int
        var id: String { name }
    }

    private func categoryShares(now: Date) -> [CategoryShare] {
        visibleCategories.map { name in
            let items = model.wallpapers.filter { $0.category == name }
            return CategoryShare(name: name, total: items.count,
                                 today: items.filter { isAddedToday($0, now: now) }.count)
        }
        .filter { $0.total > 0 }   // 總覽的分布條與「幾個分類」只算有圖的
    }

    /// 「下次切換 18:42 黃昏」；跟著淺色／深色時沒有固定時刻。
    private func nextSwitchText(after date: Date) -> String {
        guard let next = DynamicSchedule.load().next(after: date) else { return L("跟著系統淺色／深色切換") }
        return L("下次切換 \(Self.clockFormatter.string(from: next.at)) \(next.phase.title)")
    }

    // MARK: - 網格

    private var stillGallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if isOverview && search.isEmpty {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        overview(now: context.date)
                    }
                }
                sectionHeader
                if visibleWallpapers.isEmpty, search.isEmpty, let name = selectedCategory, name != WallpaperLibrary.otherCategory {
                    // 還沒有圖的分類：一鍵帶著這個分類打開「產生桌布」。
                    ContentUnavailableView {
                        Label(L("「\(categoryTitle(name))」還沒有桌布"), systemImage: WallpaperPalette.categorySymbol(name))
                    } description: {
                        Text(PromptTemplate.shared.contains { $0.category == name && $0.local != nil }
                             ? "這個分類在本機直接畫，不花 API 額度，幾秒就好。" : "用你的 OpenAI API 額度生成。")
                    } actions: {
                        Button("產生這個分類", systemImage: "wand.and.rays") {
                            var recipe = model.manualRecipe
                            recipe.styles = []
                            recipe.setCategory(name, on: true)
                            model.manualRecipe = recipe
                            showGeneration = true
                        }
                        .buttonStyle(PrimaryCapsuleStyle())
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else if visibleWallpapers.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "尚無桌布" : "找不到桌布",
                        systemImage: isFavorites ? "heart" : "photo.on.rectangle",
                        description: Text(isFavorites && search.isEmpty
                            ? "選取圖片，按愛心加入收藏。" : "試試其他搜尋文字，或產生新的桌布。"))
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(visibleWallpapers) { wallpaper in
                            wallpaperCard(wallpaper)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, floatingClearance)
        }
    }

    private var sectionHeader: some View {
        let color: Color = {
            if let name = selectedCategory { return WallpaperPalette.categoryColor(name) }
            if let name = selectedTag, let tag = model.tags.first(where: { $0.name == name }) {
                return WallpaperPalette.hex(string: tag.color)
            }
            if let tier = selectedTier { return WallpaperPalette.resolutionColor(tier) }
            return isFavorites ? WallpaperSection.favorites.color : WallpaperSection.all.color
        }()
        return HStack(spacing: 10) {
            Text(section?.title ?? L("所有桌布"))
                .font(.system(size: 22, weight: .semibold))
            Pill(text: L("\(visibleWallpapers.count) 張"), color: color)
            Spacer()
        }
    }

    private func wallpaperCard(_ wallpaper: Wallpaper) -> some View {
        let selected = model.selection.ids.contains(wallpaper.id)
        return Button {
            model.click(wallpaper, modifiers: Self.currentModifiers(), order: visibleWallpapers.map(\.id))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail(wallpaper.url, radius: 12)
                HStack(spacing: 8) {
                    IconTile(symbol: WallpaperPalette.categorySymbol(wallpaper.category),
                             color: WallpaperPalette.categoryColor(wallpaper.category), size: 20)
                    // 標題 1 行省略（完整名稱在 tooltip），分類藥丸與解析度不被擠。
                    Text(displayTitle(wallpaper))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                        .help(displayTitle(wallpaper))
                    Pill(text: categoryTitle(wallpaper.category),
                         color: WallpaperPalette.categoryColor(wallpaper.category), fontSize: 10)
                        .fixedSize()
                        .layoutPriority(2)
                    Spacer(minLength: 4)
                    if model.favoriteIDs.contains(wallpaper.id) {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(WallpaperSection.favorites.color)
                            .accessibilityLabel("已收藏")
                    }
                    Text(wallpaper.pixelText)
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(WallpaperPalette.secondaryText)
                        .lineLimit(1).fixedSize()
                        .layoutPriority(2)
                }
                .frame(height: 22)
            }
            .padding(10)
            .wallpaperCard(selected: selected)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).accessibilityLabel("選取 \(displayTitle(wallpaper))")
        .simultaneousGesture(TapGesture(count: 2).onEnded { openPreview(wallpaper) })
        .contextMenu {
            let targets = contextTargets(for: wallpaper)
            Button("預覽") { openPreview(wallpaper) }
            Button("設為桌布") { Task { await model.apply(wallpaper) } }
                .disabled(model.isApplying || targets.count > 1)
            Button(model.favoriteIDs.contains(wallpaper.id) ? "取消收藏" : "加入收藏") {
                model.toggleFavorite(wallpaper)
            }
            Menu("標籤") {
                if model.tags.isEmpty {
                    Text("還沒有標籤")
                }
                ForEach(model.tags) { tag in
                    Toggle(isOn: Binding(get: { model.allHaveTag(tag.name, ids: targets) },
                                         set: { _ in model.toggleTag(tag.name, for: targets) })) {
                        Text(tag.name)
                    }
                }
                Divider()
                Button("新增標籤…") { tagDraft = TagDraft(original: nil, name: "", color: TagStore.palette[model.tags.count % TagStore.palette.count]) }
            }
            Button("在 Finder 中顯示") {
                NSWorkspace.shared.activateFileViewerSelecting(model.wallpapers.filter { targets.contains($0.id) }.map(\.url))
            }
            Divider()
            Button(targets.count > 1 ? L("將 \(targets.count) 張移到垃圾桶…") : L("移到垃圾桶…"), role: .destructive) {
                pendingTrash = targets
            }
        }
    }

    /// 右鍵在已選取的卡片上 → 對「可見選取」；否則只對那一張。
    /// 右鍵、浮動列、Delete 都用同一個可見選取集合。
    private func contextTargets(for wallpaper: Wallpaper) -> Set<String> {
        let visibleSelection = Set(selectedVisible.map(\.id))
        return visibleSelection.contains(wallpaper.id) ? visibleSelection : [wallpaper.id]
    }

    /// 選取裁成畫面上看得到的；裁完是空的就選第一張可見的。
    private func syncSelectionToVisible() {
        model.selection = SelectionLogic.restrict(model.selection, toVisible: visibleWallpapers.map(\.id))
        if model.selection.ids.isEmpty, let first = visibleWallpapers.first { model.selectedID = first.id }
    }

    static func currentModifiers() -> SelectionModifiers {
        let flags = NSEvent.modifierFlags
        var result: SelectionModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        return result
    }

    @ViewBuilder
    private func tagRowMenu(_ tag: WallpaperTag) -> some View {
        Button("重新命名…") { tagDraft = TagDraft(original: tag.name, name: tag.name, color: tag.color) }
        Menu("改顏色") {
            ForEach(TagStore.palette, id: \.self) { color in
                Button {
                    model.editTags { try $0.recolorTag(tag.name, color: color) }
                } label: {
                    Label { Text(verbatim: color) } icon: { Image(nsImage: Self.swatch(color)) }
                }
            }
        }
        Divider()
        Button("刪除標籤", role: .destructive) {
            if model.editTags({ try $0.deleteTag(tag.name) }), section == .tag(tag.name) { section = .section(.all) }
        }
    }

    /// 選單裡的小色塊（Menu 只吃 NSImage）。
    static func swatch(_ hex: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(WallpaperPalette.hex(string: hex)).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return image
    }

    // MARK: - Overview

    private func overview(now: Date) -> some View {
        let shares = categoryShares(now: now)
        let todayTotal = shares.reduce(0) { $0 + $1.today }
        var facts: [String] = []
        if todayTotal > 0 { facts.append(L("今天新增 \(todayTotal) 張")) }
        if model.isDynamicActive {
            facts.append(nextSwitchText(after: now))
        }
        facts.append(L("\(shares.count) 個分類"))
        return VStack(alignment: .leading, spacing: 0) {
            Text("UTUVO Wallpaper 為你準備了")
                .font(.system(size: 17))
                .foregroundStyle(WallpaperPalette.secondaryText)
            Text("\(model.wallpapers.count) 張桌布")
                .font(.system(size: 64, weight: .bold))
                .tracking(-1.5)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
                .padding(.top, 2)
            Text(facts.joined(separator: " · "))
                .font(.system(size: 15))
                .foregroundStyle(WallpaperPalette.secondaryText)
                .monospacedDigit()
                .lineLimit(1).truncationMode(.tail)
            if !shares.isEmpty {
                distributionBar(shares)
                    .padding(.top, 22)
                Label {
                    Text("實心是今天新的，斜線是之前的。點一段可打開該分類。")
                } icon: {
                    Image(systemName: "hand.point.up.left")
                }
                .font(.system(size: 12))
                .foregroundStyle(WallpaperPalette.secondaryText)
                .padding(.top, 10)
            }
            statusCard(now: now)
                .padding(.top, 22)
        }
    }

    /// 各段寬度：先依張數比例、套最小寬，再整體等比縮放，總寬恰好等於可用寬度、不溢出。
    static func segmentWidths(_ counts: [Int], available: CGFloat, minimum: CGFloat = 10) -> [CGFloat] {
        let total = counts.reduce(0, +)
        guard total > 0, available > 0 else { return counts.map { _ in 0 } }
        let floored = counts.map { max(available * CGFloat($0) / CGFloat(total), minimum) }
        let scale = available / floored.reduce(0, +)
        return floored.map { $0 * scale }
    }

    private func distributionBar(_ allShares: [CategoryShare]) -> some View {
        let shares = allShares.filter { $0.total > 0 }
        let gap: CGFloat = 6
        return GeometryReader { geometry in
            let available = max(geometry.size.width - gap * CGFloat(max(shares.count - 1, 0)), 0)
            let widths = Self.segmentWidths(shares.map(\.total), available: available)
            HStack(spacing: gap) {
                ForEach(Array(shares.enumerated()), id: \.element.id) { offset, share in
                    let width = widths[offset]
                    let solid = share.total > 0 ? width * CGFloat(share.today) / CGFloat(share.total) : 0
                    let color = WallpaperPalette.categoryColor(share.name)
                    Button { section = .category(share.name) } label: {
                        HStack(spacing: 0) {
                            if solid > 0 { color.frame(width: solid) }
                            if share.today < share.total { StripeFill(color: color) }
                        }
                        .frame(width: width)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .help("\(categoryTitle(share.name)) · \(share.total) 張")
                    .accessibilityLabel("\(categoryTitle(share.name)) · \(share.total) 張")
                }
            }
        }
        .frame(height: 56 - 12)
        .padding(6)
        .modifier(DistributionContainer())
    }

    private enum StatusTone { case green, blue, orange, neutral }

    @ViewBuilder
    private func statusCard(now: Date) -> some View {
        if let error = model.errorMessage {
            statusCardBody(tone: .orange, symbol: "exclamationmark",
                           title: L("需要注意"), detail: error) {
                Button("關閉") { model.errorMessage = nil }
            }
        } else if model.isGenerating {
            statusCardBody(tone: .blue, symbol: "wand.and.rays",
                           title: L("正在產生桌布"),
                           detail: model.generationProgress.isEmpty ? L("請稍候…") : model.generationProgress,
                           showsProgress: true) {
                Button("取消生成") { model.cancelGeneration() }
            }
        } else if model.isDynamicActive {
            let current = DynamicPhase.current(at: now)
            statusCardBody(tone: .green, symbol: "checkmark",
                           title: L("日夜模式已啟用"),
                           detail: L("現在是\(current.title)，\(nextSwitchText(after: now))。")) {
                Button("查看") { section = .section(.dynamic) }
            }
        } else {
            statusCardBody(tone: .neutral, symbol: "calendar",
                           title: L("每日生成：\(model.dailyMode.title)"),
                           detail: model.dailyMode == .off
                               ? L("目前不會自動產生新桌布。可在「輪換與每日生成」開啟。")
                               : L("每天自動產生一批新桌布，使用 API 額度。")) {
                Button("設定") { showSchedule = true }
            }
        }
    }

    private func statusCardBody<Action: View>(tone: StatusTone, symbol: String, title: String, detail: String,
                                              showsProgress: Bool = false,
                                              @ViewBuilder action: () -> Action) -> some View {
        let color: Color = {
            switch tone {
            case .green: return WallpaperPalette.green
            case .blue: return WallpaperPalette.blue
            case .orange: return WallpaperPalette.orange
            case .neutral: return WallpaperPalette.hex(0x8E8E93)
            }
        }()
        return HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 44, glass: {
                switch tone {
                case .green: return "nature"
                case .blue: return "all"
                case .orange: return "dynamic"
                case .neutral: return "minimal"
                }
            }())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(WallpaperPalette.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if showsProgress {
                    ProgressView().progressViewStyle(.linear).tint(color).padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            action().buttonStyle(SecondaryCapsuleStyle())
        }
        .padding(16)
        .modifier(StatusCardBackground(color: color))
    }

    // MARK: - 浮動操作列

    private var floatingBar: some View {
        HStack(spacing: 14) {
            if isDynamic {
                VStack(alignment: .leading, spacing: 1) {
                    Text("日夜桌布").font(.system(size: 13, weight: .semibold))
                    Text("4 個時段 · \(previewedScene?.resolution ?? L("尚無圖片"))")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(WallpaperPalette.secondaryText)
                }
            } else if selectedVisible.count > 1 {
                let picked = selectedVisible
                Text("已選 \(picked.count) 張").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Text(totalSizeText(picked))
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(WallpaperPalette.secondaryText)
                    .lineLimit(1)
                Button("移到垃圾桶") { pendingTrash = Set(picked.map(\.id)) }
                    .buttonStyle(DestructiveCapsuleStyle())
                    .help("移到垃圾桶（可以從垃圾桶救回）")
            } else if let wallpaper = inspected {
                Text("已選 1 張").font(.system(size: 13, weight: .semibold))
                Text("\(wallpaper.pixelText) · \(categoryTitle(wallpaper.category))")
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(WallpaperPalette.secondaryText)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    Button { browse(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                        .accessibilityLabel("上一張").help("上一張")
                    Button { browse(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                        .accessibilityLabel("下一張").help("下一張")
                }
                .buttonStyle(.borderless)
            } else {
                Text("尚未選取桌布").font(.system(size: 13)).foregroundStyle(WallpaperPalette.secondaryText)
            }
            Button(model.isApplying ? "套用中…" : "設為桌布") {
                if isDynamic {
                    let directory = previewedScene?.directory
                    Task { await model.activateDynamic(directory: directory) }
                } else if let wallpaper = inspected {
                    Task { await model.apply(wallpaper) }
                }
            }
            .buttonStyle(PrimaryCapsuleStyle())
            .disabled(model.isApplying || (isDynamic ? !(previewedScene.map { DynamicSceneEntry.isComplete($0.directory) } ?? false) : (inspected == nil || selectedVisible.count > 1)))
            .help(!isDynamic && selectedVisible.count > 1 ? L("一次只能設一張") : L("設為桌布"))
        }
        .padding(.leading, 20).padding(.trailing, 7).padding(.vertical, 7)
        .modifier(FloatingBarGlass(shadowOpacity: colorScheme == .dark ? 0.25 : 0.12))
    }

    // MARK: - 動態桌布

    /// 正在預覽的場景：使用者點的 → 背景正在用的 → 目前場景 → 第一個。
    private var previewedScene: DynamicSceneEntry? {
        if let sceneID, let picked = scenes.first(where: { $0.id == sceneID }) { return picked }
        if let active = model.activeDynamicDirectory?.standardizedFileURL.path,
           let entry = scenes.first(where: { $0.id == active }) { return entry }
        let current = DynamicScene.directory.standardizedFileURL.path
        return scenes.first { $0.id == current } ?? scenes.first
    }

    private func isActiveScene(_ entry: DynamicSceneEntry) -> Bool {
        model.activeDynamicDirectory?.standardizedFileURL.path == entry.id
    }

    private func reloadScenes() { scenes = DynamicSceneLibrary.load() }

    private var dynamicGallery: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let current = DynamicPhase.current(at: now)
            let shown = hoverPhase ?? previewPhase ?? current
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let scene = previewedScene {
                        dynamicHero(scene, phase: shown, isNow: shown == current)
                        if DynamicTiming.load() == .appearance {
                            Label("跟著系統淺色／深色：淺色顯示白天、深色顯示夜晚。", systemImage: "circle.lefthalf.filled")
                                .font(.system(size: 13)).foregroundStyle(WallpaperPalette.secondaryText)
                        } else {
                            dynamicTimeline(now: now, shown: shown)
                        }
                        phaseCards(current: current, shown: shown)
                    } else {
                        ContentUnavailableView("尚無日夜場景", systemImage: "sun.max",
                                               description: Text("用下方描述生成四時段場景。"))
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }
                    sceneLibrary
                    generationCard
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, floatingClearance)
            }
        }
    }

    private func dynamicHero(_ scene: DynamicSceneEntry, phase: DynamicPhase, isNow: Bool) -> some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image = ThumbnailCache.image(for: scene.imageURL(phase), maxPixel: 1800) {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        // 大圖固定高度（裁切填滿），讓時間軸與場景庫在一般視窗高度內看得到。
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Image(systemName: phase.symbol)
                    Text(isNow ? L("現在 · \(phase.title) · \(phase.range)") : L("預覽 · \(phase.title) · \(phase.range)"))
                        .monospacedDigit()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .modifier(HeroLabelBackground())
                .padding(14)
            }
            .overlay(alignment: .bottomLeading) {
                Text(DynamicScene.shortTitle(scene.title))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .padding(.horizontal, 16).padding(.bottom, 14)
                    .padding(.trailing, 120)
            }
            .help(scene.title)
            .animation(.easeOut(duration: 0.15), value: phase)
    }

    /// 時段色對應到同色的玻璃方塊。
    static func phaseGlass(_ phase: DynamicPhase) -> String {
        switch phase {
        case .dawn: return "dynamic"
        case .day: return "watercolor"
        case .dusk: return "animation"
        case .night: return "cosmic"
        }
    }

    static func phaseColor(_ phase: DynamicPhase) -> Color {
        switch phase {
        case .dawn: return WallpaperPalette.hex(0xFF9F0A)
        case .day: return WallpaperPalette.hex(0x40C8E0)
        case .dusk: return WallpaperPalette.hex(0xFF6482)
        case .night: return WallpaperPalette.hex(0x5E5CE6)
        }
    }

    private func dynamicTimeline(now: Date, shown: DynamicPhase) -> some View {
        let segments = DynamicSchedule.load().segments(on: now)
        let fraction = DynamicPhase.dayFraction(at: now)
        let ticks = [0] + segments.dropFirst().map(\.start) + [1440]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("24 小時").font(.system(size: 13, weight: .semibold))
                Text(previewPhase == nil ? L("滑過預覽，點一段固定預覽") : L("已固定預覽\(previewPhase!.title)"))
                    .font(.system(size: 12)).foregroundStyle(WallpaperPalette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("現在") { previewPhase = nil; hoverPhase = nil }
                    .buttonStyle(SecondaryCapsuleStyle())
                    .disabled(previewPhase == nil)
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            let active = segment.phase == shown
                            Self.phaseColor(segment.phase)
                                .opacity(active ? 1 : 0.6)
                                .frame(width: width * CGFloat(segment.end - segment.start) / 1440)
                                .overlay(alignment: .leading) { Rectangle().fill(Color.black.opacity(0.18)).frame(width: 1) }
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { hoverPhase = segment.phase }
                                    else if hoverPhase == segment.phase { hoverPhase = nil }
                                }
                                .onTapGesture { previewPhase = segment.phase }
                                .help("\(segment.phase.title) · \(segment.phase.range)")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(L("預覽\(segment.phase.title) \(segment.phase.range)"))
                        }
                    }
                    .frame(height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    // 「現在」指示線
                    Capsule().fill(Color.primary)
                        .frame(width: 3, height: 40)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .offset(x: width * fraction - 1.5, y: -5)
                        .allowsHitTesting(false)
                    Text(Self.clockFormatter.string(from: now))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary))
                        .foregroundStyle(WallpaperPalette.canvas)
                        .position(x: min(max(width * fraction, 24), width - 24), y: 46)
                        .allowsHitTesting(false)
                    ForEach(ticks, id: \.self) { minute in
                        Text(minute % 60 == 0 ? String(format: "%02d", minute / 60) : DynamicSchedule.clock(minute))
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(WallpaperPalette.secondaryText)
                            .fixedSize()
                            .position(x: min(max(width * CGFloat(minute) / 1440, 12), width - 12), y: 64)
                            .opacity(abs(width * CGFloat(minute) / 1440 - width * fraction) < 30 ? 0 : 1)
                    }
                }
            }
            .frame(height: 72)
        }
        .padding(16)
        .glassPanel(radius: 16)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func phaseCards(current: DynamicPhase, shown: DynamicPhase) -> some View {
        HStack(spacing: 12) {
            ForEach(DynamicPhase.allCases) { phase in
                Button { previewPhase = phase } label: {
                    HStack(spacing: 10) {
                        IconTile(symbol: phase.symbol, color: Self.phaseColor(phase), size: 28, glass: Self.phaseGlass(phase))
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(phase.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                if phase == current {
                                    Text("現在").font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(WallpaperPalette.accent).lineLimit(1)
                                }
                            }
                            Text(phase.range).font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(WallpaperPalette.secondaryText).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .wallpaperCard(radius: 12, selected: phase == current)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(phase == shown && phase != current ? 0.35 : 0), lineWidth: 1.5))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("預覽\(phase.title) \(phase.range)"))
            }
        }
    }

    private static let sceneDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private var sceneLibrary: some View {
        let visible = scenes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("場景庫").font(.system(size: 22, weight: .semibold))
                Pill(text: L("\(visible.count) 個場景"), color: WallpaperSection.dynamic.color).fixedSize()
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(visible) { entry in
                    Button { sceneID = entry.id; previewPhase = nil } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            thumbnail(entry.imageURL(.day), radius: 10)
                            Text(DynamicScene.shortTitle(entry.title))
                                .help(entry.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(2).truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                            HStack(spacing: 6) {
                                Text(entry.created.map { Self.sceneDateFormatter.string(from: $0) } ?? "—")
                                    .font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(WallpaperPalette.secondaryText).lineLimit(1)
                                Spacer(minLength: 4)
                                if isActiveScene(entry) {
                                    Pill(text: L("使用中"), color: WallpaperPalette.green, fontSize: 10).fixedSize()
                                }
                                if entry.isBuiltIn {
                                    Pill(text: L("內建示範"), color: WallpaperPalette.hex(0x636366), fontSize: 10).fixedSize()
                                }
                            }
                        }
                        .padding(8)
                        .wallpaperCard(radius: 14, selected: previewedScene?.id == entry.id)
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("預覽場景 \(entry.title)"))
                }
            }
        }
    }

    private var generationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: "wand.and.rays", color: WallpaperSection.dynamic.color, size: 28)
                Text("生成自己的日夜桌布").font(.system(size: 17, weight: .semibold))
            }
            Picker("場景來源", selection: $model.dynamicAutoFrequency) {
                ForEach(DynamicAutoFrequency.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if model.dynamicAutoFrequency == .off {
                HStack(alignment: .top, spacing: 8) {
                    TextField("描述同一個場景", text: $scenePrompt, prompt: Text(L("例如：手繪動畫風的海邊小鎮巷弄、窗台上打盹的貓（水彩）、雨天的街角咖啡店")), axis: .vertical)
                        .lineLimit(2...4)
                        .glassField()
                    InspirationButton {
                        scenePrompt = DynamicAutoPlanner.pick(period: UUID().uuidString, season: DynamicAutoPlanner.season(for: Date()),
                                                              recent: [], chinese: isChineseUI).prompt
                    }
                }
            } else {
                autoSceneInfo
            }
            Text("先生成白天，再參考同一張原圖編修清晨、黃昏、夜晚；原圖保留，成品為 6144 × 3456 重採樣。")
                .font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if model.isGenerating {
                generationSteps
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.generationProgress).font(.callout)
                    Spacer()
                    Button("取消生成") { model.cancelGeneration() }.buttonStyle(SecondaryCapsuleStyle())
                }
            } else {
                if model.dynamicAutoFrequency == .off {
                    Button("生成四時段 6K") { model.startDynamicGeneration(prompt: scenePrompt) }
                        .buttonStyle(PrimaryCapsuleStyle())
                        .disabled(scenePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("現在用 AI 生成一組") { model.generateAutoSceneNow() }
                        .buttonStyle(PrimaryCapsuleStyle())
                }
            }
        }
        .padding(18)
        .wallpaperCard()
    }

    /// AI 自動：說明＋上一組狀態。
    private var autoSceneInfo: some View {
        let state = model.dynamicAutoState
        return VStack(alignment: .leading, spacing: 6) {
            Text(model.dynamicAutoFrequency == .daily
                 ? "AI 每天依季節挑一個新場景，自動生成四時段；日夜模式開著會直接換上。"
                 : "AI 每週依季節挑一個新場景，自動生成四時段；日夜模式開著會直接換上。")
                .fixedSize(horizontal: false, vertical: true)
            Text("每組 4 次圖片生成，使用你的 OpenAI API 額度。需要背景服務或保持 App 開著。")
                .foregroundStyle(WallpaperPalette.secondaryText)
            if let state {
                Text(state.completed ? L("上一組：\(state.prompt)")
                     : state.attempts >= DynamicAutoState.maxAttempts ? L("這一期未完成：\(state.prompt)")
                     : L("進行中：\(state.prompt)"))
                    .foregroundStyle(WallpaperPalette.secondaryText).lineLimit(2)
            }
        }
        .font(.callout)
    }

    /// 四步驟：白天 → 清晨 → 黃昏 → 夜晚（與生成順序一致），完成打勾。
    private var generationSteps: some View {
        let steps: [DynamicPhase] = [.day, .dawn, .dusk, .night]
        return HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, phase in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WallpaperPalette.secondaryText)
                }
                HStack(spacing: 5) {
                    if index < model.dynamicStepsDone {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(WallpaperPalette.green)
                    } else if index == model.dynamicStepsDone {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "circle").foregroundStyle(WallpaperPalette.secondaryText)
                    }
                    Text(phase.title).font(.system(size: 12, weight: index == model.dynamicStepsDone ? .semibold : .regular))
                }
            }
        }
    }

    // MARK: - 檢視器

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isDynamic {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let phase = hoverPhase ?? previewPhase ?? DynamicPhase.current(at: context.date)
                        VStack(alignment: .leading, spacing: 8) {
                            if let scene = previewedScene { thumbnail(scene.imageURL(phase), radius: 12) }
                            Text(DynamicScene.shortTitle(previewedScene?.title ?? DynamicScene.title)).font(.headline).lineLimit(2)
                                .truncationMode(.tail)
                                .help(previewedScene?.title ?? DynamicScene.title)
                            Text("\(phase.title) · \(phase.range)").font(.caption).monospacedDigit()
                                .foregroundStyle(WallpaperPalette.secondaryText)
                        }
                    }
                    infoCard(title: "圖片") {
                        infoRow("解析度", previewedScene?.resolution ?? L("尚無圖片"))
                        infoRow("格式", L("HEIC · 4 個時段"))
                        infoRow("切換方式", L("App 背景時段排程"))
                        HStack(spacing: 6) {
                            Circle().fill(model.isDynamicActive ? WallpaperPalette.green : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(model.isDynamicActive ? "日夜模式已啟用，一般輪換暫停" : "設定後由背景自動切換時段")
                                .font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
                        }
                    }
                    infoCard(title: "桌面") { displayPicker; inspectorApplyButton(wallpaper: nil) }
                    Button("匯出 HEIC…", systemImage: "square.and.arrow.up") { exportDynamic() }
                        .buttonStyle(SecondaryCapsuleStyle())
                        .disabled(previewedScene?.hasExport != true)
                } else if let wallpaper = inspected {
                    Button { openPreview(wallpaper) } label: {
                        thumbnail(wallpaper.url, radius: 12)
                            .overlay(alignment: .bottomTrailing) {
                                Label("預覽", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .modifier(HeroLabelBackground())
                                    .foregroundStyle(.white)
                                    .padding(8)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("放大預覽（也可以在縮圖上按兩下）")
                    HStack(spacing: 8) {
                        IconTile(symbol: WallpaperPalette.categorySymbol(wallpaper.category),
                                 color: WallpaperPalette.categoryColor(wallpaper.category), size: 24)
                        Text(displayTitle(wallpaper)).font(.headline).lineLimit(2)
                        Spacer()
                        Button { model.toggleFavorite(wallpaper) } label: {
                            Image(systemName: model.favoriteIDs.contains(wallpaper.id) ? "heart.fill" : "heart")
                                .foregroundStyle(model.favoriteIDs.contains(wallpaper.id)
                                                 ? WallpaperSection.favorites.color : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(model.favoriteIDs.contains(wallpaper.id) ? "取消收藏" : "加入收藏")
                    }
                    tagPills(for: wallpaper)
                    infoCard(title: "圖片") {
                        infoRow("解析度", wallpaper.pixelText)
                        infoRow("檔案大小", wallpaper.sizeText)
                        infoRow("影像來源", wallpaper.origin.label)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("檔案").font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
                            Text(wallpaper.name).font(.caption).lineLimit(3).textSelection(.enabled)
                        }
                    }
                    infoCard(title: "桌面") { displayPicker; inspectorApplyButton(wallpaper: wallpaper) }
                } else {
                    ContentUnavailableView("選取桌布", systemImage: "photo")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(16)
        }
        .panelBackground()
    }

    private func tagPills(for wallpaper: Wallpaper) -> some View {
        let assigned = model.tags(for: wallpaper)
        let unassigned = model.tags.filter { tag in !assigned.contains(tag) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("標籤").font(.system(size: 12, weight: .semibold)).foregroundStyle(WallpaperPalette.secondaryText)
            FlowLayout(spacing: 6) {
                ForEach(assigned) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Button { model.editTags { try $0.set(tag.name, assigned: false, for: [wallpaper.id]) } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("移除標籤 \(tag.name)"))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(WallpaperPalette.muted(tag.color)))
                }
                Menu {
                    ForEach(unassigned) { tag in
                        Button(tag.name) { model.editTags { try $0.set(tag.name, assigned: true, for: [wallpaper.id]) } }
                    }
                    if !unassigned.isEmpty { Divider() }
                    Button("新增標籤…") { tagDraft = TagDraft(original: nil, name: "", color: TagStore.palette[model.tags.count % TagStore.palette.count]) }
                } label: {
                    Label(assigned.isEmpty ? L("加入標籤") : L("加入"), systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().strokeBorder(Color.primary.opacity(0.18)))
            }
        }
    }

    private func infoCard<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(WallpaperPalette.secondaryText)
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .wallpaperCard(radius: 12)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(WallpaperPalette.secondaryText)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    /// 資訊欄裡的「設為桌布」：選完螢幕就近按，不必回去找底部工具列。
    private func inspectorApplyButton(wallpaper: Wallpaper?) -> some View {
        Button(model.isApplying ? "套用中…" : "設為桌布", systemImage: "photo.on.rectangle") {
            if let wallpaper { Task { await model.apply(wallpaper) } }
            else { let directory = previewedScene?.directory; Task { await model.activateDynamic(directory: directory) } }
        }
        .buttonStyle(PrimaryCapsuleStyle())
        .frame(maxWidth: .infinity, alignment: .trailing)
        .disabled(model.isApplying || (wallpaper == nil && !(previewedScene.map { DynamicSceneEntry.isComplete($0.directory) } ?? false)))
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

    private func thumbnail(_ url: URL, radius: CGFloat, maxPixel: CGFloat = 900) -> some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.06)
                if let image = ThumbnailCache.image(for: url, maxPixel: maxPixel) {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .aspectRatio(16.0 / 9, contentMode: .fit)
    }

    /// 宣傳截圖用：啟動參數 `-UTUVOShowcase generate|preview|dynamic|schedule` 直接打開該畫面（不帶參數時不做事）。
    private func openScreenshotState() {
        guard let state = AppDefaults.shared.string(forKey: "UTUVOShowcase") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            switch state {
            case "generate": showGeneration = true
            case "schedule": showSchedule = true
            case "dynamic": section = .section(.dynamic)
            case "preview": if let first = visibleWallpapers.first { openPreview(first) }
            default: break
            }
        }
    }

    // MARK: - 大圖預覽

    private func openPreview(_ wallpaper: Wallpaper) {
        model.select(wallpaper)
        withAnimation(.easeOut(duration: 0.18)) { previewID = wallpaper.id }
    }

    private func stepPreview(_ delta: Int) {
        guard let id = previewID, let index = visibleWallpapers.firstIndex(where: { $0.id == id }), !visibleWallpapers.isEmpty else { return }
        let next = visibleWallpapers[(index + delta + visibleWallpapers.count) % visibleWallpapers.count]
        model.select(next)
        previewID = next.id
    }

    /// 蓋住整個主畫面的大圖：←／→ 換張、Esc 關閉，可以直接設為桌布。
    private func previewOverlay(_ wallpaper: Wallpaper) -> some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
                .onTapGesture { previewID = nil }
            if let image = ThumbnailCache.image(for: wallpaper.url, maxPixel: 3000) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                    .padding(.horizontal, 20).padding(.top, 50).padding(.bottom, 70)
                    .id(wallpaper.id)
                    .transition(.opacity)
            }
            VStack {
                HStack(spacing: 10) {
                    Text(displayTitle(wallpaper)).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(wallpaper.pixelText).font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { previewID = nil } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                        .glassControl()
                        .keyboardShortcut(.cancelAction)
                        .help("關閉（Esc）")
                }
                .padding(.horizontal, 20).padding(.top, 14)
                Spacer()
                HStack(spacing: 12) {
                    Button { stepPreview(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                        .glassControl()
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .help("上一張（←）")
                    Button(model.isApplying ? "套用中…" : "設為桌布", systemImage: "photo.on.rectangle") {
                        Task { await model.apply(wallpaper) }
                    }
                    .buttonStyle(PrimaryCapsuleStyle())
                    .disabled(model.isApplying)
                    Button { stepPreview(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                        .glassControl()
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .help("下一張（→）")
                }
                .padding(.bottom, 22)
            }
        }
        .transition(.opacity)
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
            .glassControl()
            Text("原生 3840 × 2160，另存 6144 × 3456 的 6K 重採樣版本。使用現有 API 憑證。")
                .font(.caption).foregroundStyle(WallpaperPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            LabeledContent("分類") { categoryMenu($model.manualRecipe) }
            HStack(alignment: .top, spacing: 8) {
                TextField("自己的 Prompt（選填）", text: Binding(get: { model.manualRecipe.idea },
                                                              set: { model.manualRecipe.idea = String($0.prefix(DailyRecipe.ideaLimit)) }),
                          prompt: Text("例如：台北的老公寓陽台"), axis: .vertical)
                    .lineLimit(2...4).glassField()
                InspirationButton {
                    model.manualRecipe.idea = PromptInspiration.pick(categories: model.manualRecipe.categories,
                                                                     current: model.manualRecipe.idea, chinese: isChineseUI)
                }
            }
            Text(model.manualRecipe.trimmedIdea.isEmpty
                 ? "每張換主題、配色、光線與構圖。"
                 : "每張都畫你的 Prompt，用選的分類輪流表現。")
                .font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
            if model.isGenerating {
                ProgressView().controlSize(.small)
                Text(model.generationProgress).font(.callout)
                Button("取消生成") { model.cancelGeneration() }
            } else {
                Button("產生 \(model.generateCount) 張") { model.startGeneration(count: model.generateCount) }
                    .buttonStyle(PrimaryCapsuleStyle())
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
                Toggle("每顆螢幕輪換不同張", isOn: $model.rotationPerDisplay)
                    .disabled(model.targetDisplayID != nil)
                    .help("只在「套用到：所有螢幕」時有效")
                Toggle("暫停輪換與日夜切換", isOn: Binding(get: { model.isRotationPaused }, set: { model.setRotationPaused($0) }))
            }
            Section("日夜切換時間") {
                DynamicTimingControls { model.dynamicRevision += 1 }
            }
            Section("每日生成") {
                Picker("張數", selection: Binding(get: { model.dailyMode }, set: { model.setDailyMode($0) })) {
                    ForEach(DailyScheduler.Mode.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("分類") { categoryMenu($model.dailyRecipe) }
                HStack(alignment: .top, spacing: 8) {
                    TextField("自己的 Prompt（選填）", text: Binding(get: { model.dailyRecipe.idea },
                                                         set: { model.dailyRecipe.idea = String($0.prefix(DailyRecipe.ideaLimit)) }),
                              prompt: Text("例如：台北的老公寓陽台"), axis: .vertical)
                        .lineLimit(1...3)
                    InspirationButton {
                        model.dailyRecipe.idea = PromptInspiration.pick(categories: model.dailyRecipe.categories,
                                                                        current: model.dailyRecipe.idea, chinese: isChineseUI)
                    }
                }
                Text(model.dailyRecipe.trimmedIdea.isEmpty
                     ? "每天換主題、配色、光線與構圖。"
                     : "每張都畫你的 Prompt，用選的分類輪流表現。")
                    .font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
                Text("設定會保留。每天最多一批，使用 API 額度。要在關閉視窗後繼續，請到設定啟用背景服務；背景只輪換 6K 成品。")
                    .font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
                Button("背景服務設定") { showSchedule = false; showSettings = true }
            }
        }
        .formStyle(.grouped).frame(width: 400, height: 660)
    }

    /// 分類多選（與側欄分類相同）：全部或挑幾種。每日排程與手動產生共用這個選單。
    private func categoryMenu(_ recipe: Binding<DailyRecipe>) -> some View {
        let selected = recipe.wrappedValue.categories
        return Menu {
            Button("全部分類") { recipe.wrappedValue.styles = [] }
            Divider()
            ForEach(DailyRecipe.categories, id: \.self) { category in
                Toggle(categoryTitle(category), isOn: Binding(
                    get: { selected.contains(category) },
                    set: { recipe.wrappedValue.setCategory(category, on: $0) }))
            }
        } label: {
            Text(selected.isEmpty ? L("全部分類")
                 : selected.count == 1 ? categoryTitle(selected[0]) : L("\(selected.count) 個分類"))
        }
        .glassControl()
        .fixedSize()
    }

    /// 背景模糊用的圖：日夜頁用場景的白天圖，其他頁用選取的桌布（小縮圖就夠）。
    private var backdropImage: NSImage? {
        let url = isDynamic ? previewedScene.map { $0.directory.appendingPathComponent("day.jpg") } : inspected?.url
        return url.flatMap { ThumbnailCache.image(for: $0, maxPixel: 320) }
    }

    /// 介面是不是中文（AI 靈感照介面語言給點子）。
    private var isChineseUI: Bool { (Bundle.main.preferredLocalizations.first ?? "zh-Hant").hasPrefix("zh") }

    private var statusBar: some View {
        HStack {
            if model.isGenerating { ProgressView().controlSize(.mini) }
            Text(model.isGenerating ? model.generationProgress : model.statusMessage)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(isDynamic ? "4 個時段" : "\(visibleWallpapers.count) 張").monospacedDigit()
            if model.dailyMode != .off { Text(model.dailyMode.title) }
        }
        .font(.caption).foregroundStyle(WallpaperPalette.secondaryText).padding(.horizontal, 16).padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(WallpaperPalette.orange)
            Spacer()
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("關閉錯誤訊息")
        }
        .font(.callout).padding(12)
        .background(WallpaperPalette.orange.opacity(0.12))
    }

    private var trashTitle: String {
        L("將 \(pendingTrash?.count ?? 0) 張移到垃圾桶？")
    }

    private func totalSizeText(_ items: [Wallpaper]) -> String {
        let bytes = items.reduce(Int64(0)) { total, item in
            total + Int64((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return L("共 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
    }

    /// ⌘A／Esc／Delete／⌘⌫：文字欄位裡有字時讓給文字欄位，不搶搜尋框的按鍵。
    /// （搜尋框啟動時就拿到焦點；空的時候這些鍵對它沒有作用，所以交給圖庫。）
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 確認視窗、標籤表單、任何 modal 開著時一律不攔（Esc 要留給它們取消）。
            guard pendingTrash == nil, tagDraft == nil, NSApp.modalWindow == nil,
                  let window = event.window, window.isKeyWindow, window.isMainWindow,
                  window.attachedSheet == nil, !(window is NSPanel) else { return event }
            if let text = window.firstResponder as? NSText, !text.string.isEmpty { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // 大圖預覽開著：Esc 關預覽、←／→ 換張，其他鍵照舊（不會誤刪、不會清掉選取）。
            if previewID != nil, flags.isDisjoint(with: [.command, .option, .control, .shift]) {
                switch event.keyCode {
                case 53: previewID = nil; return nil
                case 123: stepPreview(-1); return nil
                case 124: stepPreview(1); return nil
                case 51, 117: return nil
                default: return event
                }
            }
            guard !isDynamic else { return event }
            let order = visibleWallpapers.map(\.id)
            switch event.keyCode {
            case 0 where flags == .command:                       // ⌘A
                model.selectAll(order: order); return nil
            case 53 where flags.isEmpty:                            // Esc
                guard !model.selection.ids.isEmpty else { return event }
                model.clearSelection(); return nil
            case 51 where flags.isEmpty || flags == .command,       // Delete／⌘⌫
                 117 where flags.isEmpty || flags == .function:     // ⌦
                let ids = Set(selectedVisible.map(\.id))
                guard !ids.isEmpty else { return event }
                pendingTrash = ids; return nil
            default:
                return event
            }
        }
    }

    private func displayTitle(_ wallpaper: Wallpaper) -> String {
        index.titles[wallpaper.id] ?? wallpaper.url.deletingPathExtension().lastPathComponent
    }

    private func exportDynamic() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.heic]
        guard let scene = previewedScene else { return }
        panel.nameFieldStringValue = scene.title + ".heic"
        panel.canCreateDirectories = true
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                if url.standardizedFileURL != scene.heicURL.standardizedFileURL {
                    try Data(contentsOf: scene.heicURL).write(to: url, options: .atomic)
                }
                model.statusMessage = L("已匯出：\(url.lastPathComponent)")
            } catch { model.errorMessage = L("無法匯出 HEIC，請確認目的資料夾可寫入。") }
        }
    }
}

// MARK: - 顯示名稱（只影響顯示，不改檔名或資料）

/// 範本 id → 顯示名稱。字面常數讓 check.py 抽得到 key。
private func templateDisplayTitle(_ id: String) -> String? {
    switch id {
    case "nature-dawn": return L("自然風景")
    case "minimal-paper": return L("紙雕極簡")
    case "abstract-flow": return L("流動光帶")
    case "illustration-dusk": return L("插畫街景")
    case "cosmic-nebula": return L("深空")
    case "botanical-macro": return L("自然微距")
    case "watercolor-meadow": return L("水彩風景")
    case "architecture-arcade": return L("建築光影")
    case "animation-coast": return L("手繪動畫")
    case "gradient-tide": return L("柔和漸層")
    case "solid-color": return L("純色")
    case "gradient-soft": return L("漸層")
    case "dark-oled": return L("深色")
    case "geometric": return L("幾何")
    case "city": return L("城市")
    case "animals": return L("動物")
    case "render-3d": return L("3D 立體")
    default: return nil
    }
}

/// 早期示範檔：只有完全相同的檔名才用固定名稱。
private func legacyDisplayTitle(_ fileName: String) -> String? {
    switch fileName.lowercased() {
    case "abstract-flow-5k.png": return L("流光")
    case "alpine-dawn-5k.png": return L("湖畔晨光")
    case "paper-landscape-5k.png", "paper-landscape-demo-5k.jpg": return L("紙上山丘")
    default: return nil
    }
}

/// 依圖庫內容算一次所有顯示名稱與建立日期：範本標題 · 日期；同範本同日重複再加序號。
/// 只在圖庫 id 清單改變時重建（每個檔案只讀一次建立日期），畫面重繪時只查表。
struct WallpaperIndex {
    private(set) var titles: [String: String] = [:]
    private(set) var created: [String: Date] = [:]

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayFormatter() -> DateFormatter {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let formatter = DateFormatter()
        if language.hasPrefix("zh") {
            formatter.dateFormat = "M/d"
        } else {
            formatter.locale = Locale(identifier: "en_US")
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter
    }

    init() {}

    init(library: [Wallpaper]) {
        let formatter = Self.dayFormatter()
        var created: [String: Date] = [:]
        for wallpaper in library {
            created[wallpaper.id] = (try? wallpaper.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
        let bases = library.sorted { $0.name < $1.name }.map {
            ($0.id, Self.baseTitle(for: $0, created: created[$0.id], formatter: formatter))
        }
        let totals = Dictionary(grouping: bases, by: { $0.1 }).mapValues(\.count)
        var seen: [String: Int] = [:]
        var titles: [String: String] = [:]
        for (id, base) in bases {
            guard totals[base, default: 0] > 1 else { titles[id] = base; continue }
            let number = seen[base, default: 0] + 1
            seen[base] = number
            titles[id] = "\(base) · \(number)"
        }
        self.titles = titles
        self.created = created
    }

    private static func baseTitle(for wallpaper: Wallpaper, created: Date?, formatter: DateFormatter) -> String {
        if let legacy = legacyDisplayTitle(wallpaper.name) { return legacy }
        let lowered = wallpaper.name.lowercased()
        guard let template = PromptTemplate.shared.map(\.id)
            .filter({ lowered.hasPrefix($0 + "-") || lowered.hasPrefix($0 + ".") })
            .max(by: { $0.count < $1.count }),
              let name = templateDisplayTitle(template) else {
            return wallpaper.url.deletingPathExtension().lastPathComponent
        }
        var day = created ?? Date()
        if let range = lowered.range(of: #"daily-\d{4}-\d{2}-\d{2}"#, options: .regularExpression),
           let parsed = dayParser.date(from: String(lowered[range].dropFirst("daily-".count))) {
            day = parsed
        }
        return "\(name) · \(formatter.string(from: day))"
    }
}

/// 浮動操作列底：深色 material，淺色中性白（不透底圖色）。
private struct FloatingBarBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if scheme == .dark {
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        } else {
            Capsule().fill(WallpaperPalette.floatingBarLight.opacity(0.96))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.08)))
        }
    }
}


// MARK: - 標籤編輯（新增／改名＋顏色）

private struct TagEditor: View {
    @State var draft: TagDraft
    let existing: Set<String>
    let onSave: (TagDraft) -> Void
    let onCancel: () -> Void

    private var trimmed: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicate: Bool { trimmed != draft.original && existing.contains(trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "新增標籤" : "重新命名標籤").font(.headline)
            TextField("標籤名稱", text: $draft.name)
                .glassField()
                .onSubmit { if !trimmed.isEmpty && !duplicate { onSave(draft) } }
            HStack(spacing: 8) {
                ForEach(TagStore.palette, id: \.self) { color in
                    Button { draft.color = color } label: {
                        Circle().fill(WallpaperPalette.hex(string: color))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(draft.color == color ? 0.9 : 0), lineWidth: 2)
                                .padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: color))
                }
            }
            .padding(.vertical, 4)
            if duplicate {
                Text("已經有同名的標籤。").font(.caption).foregroundStyle(WallpaperPalette.orange)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button(draft.original == nil ? "新增" : "儲存") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || duplicate)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// 簡單的換行排列（藥丸用）。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


/// 縮圖快取：時間軸滑過預覽時不必每次重新解 6K JPEG。鍵含修改時間，檔案換了就重讀。
enum ThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 160
        return cache
    }()

    static func image(for url: URL, maxPixel: CGFloat) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(Int(maxPixel))|\(modified)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let cg = WallpaperLibrary.thumbnail(from: url, maxPixel: maxPixel) else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 大圖左上的小標底：macOS 26 用原生玻璃，舊系統用深色半透明膠囊。
private struct HeroLabelBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(Color.black.opacity(0.25)), in: Capsule())
        } else {
            content.background(
                Capsule().fill(Color.black.opacity(0.38))
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18))))
        }
    }
}

/// 浮動操作列：macOS 26 原生 Liquid Glass（容器讓列內玻璃按鈕融合）；舊系統用原本的 material 膠囊。
private struct FloatingBarGlass: ViewModifier {
    var shadowOpacity: Double

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 8) {
                // 淡淡壓一層底色：浮在亮圖上時字仍讀得到。
                content.glassEffect(.regular.tint(WallpaperPalette.canvas.opacity(0.55)), in: Capsule())
            }
            .shadow(color: .black.opacity(shadowOpacity * 0.6), radius: 18, y: 6)
        } else {
            content.background(FloatingBarBackground())
                .shadow(color: .black.opacity(shadowOpacity), radius: 18, y: 6)
        }
    }
}

/// 側欄選取底：macOS 26 用玻璃，舊系統用灰色圓角。
private struct SidebarSelectionBackground: ViewModifier {
    var selected: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *), selected {
            content.glassEffect(.regular.tint(WallpaperPalette.sidebarSelection.opacity(0.6)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            content.background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? WallpaperPalette.sidebarSelection : Color.clear))
        }
    }
}

/// 分類分布長條的容器。
private struct DistributionContainer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            content
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
    }
}

/// 狀態卡：macOS 26 用染色玻璃＋原本的色框；舊系統用淡色底。
private struct StatusCardBackground: ViewModifier {
    var color: Color

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.tint(color.opacity(0.16)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(0.3)))
        } else {
            content
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(color.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(0.3)))
        }
    }
}


/// 移到垃圾桶的確認視窗：不透明底、紅底白字按鈕；Esc／取消都不刪。
private struct TrashConfirmSheet: View {
    let title: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "trash.fill", color: WallpaperPalette.destructive, size: 40, glass: "favorites")
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text("原生原圖與來源資訊一起移走，可以從垃圾桶救回。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(NeutralSolidCapsuleStyle())
                Button("移到垃圾桶") { onConfirm() }
                    .buttonStyle(DestructiveCapsuleStyle())
            }
        }
        .padding(22)
        .frame(width: 380)
        .panelBackground()
        .presentationBackground(WallpaperPalette.panel)
    }
}
