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
    /// 顯示名稱與建立日期：圖庫清單改變時才算一次，render 期間只查表。
    @State private var index = WallpaperIndex()
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 440), spacing: 18)]
    /// 浮動操作列的高度＋留白；內容底部要讓出這段距離。
    private let floatingClearance: CGFloat = 96
    private var isDynamic: Bool { section == .section(.dynamic) }
    private var isFavorites: Bool { section == .section(.favorites) }
    private var isOverview: Bool { section == .section(.all) || section == nil }
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
            (item, index.created[item.id] ?? Date.distantPast)
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
            .background(CanvasBackground())
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
        .onChange(of: model.wallpapers.map(\.id), initial: true) { _, _ in
            index = WallpaperIndex(library: model.wallpapers)
        }
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
        .background(WallpaperPalette.panel)
    }

    private func sidebarRow(_ target: SidebarSelection, title: String, symbol: String, color: Color,
                            count: Int) -> some View {
        let selected = section == target
        return Button { section = target } label: {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, color: color, size: 24)
                Text(title).lineLimit(1)
                    .fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: 4)
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.primary : WallpaperPalette.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? WallpaperPalette.sidebarSelection : Color.clear))
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
        case .dynamic: return DynamicScene.isReady ? 1 : 0
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
    }

    private func nextPhase(after date: Date) -> DynamicPhase {
        let hour = Calendar.current.component(.hour, from: date)
        let ordered = DynamicPhase.allCases.sorted { $0.startHour < $1.startHour }
        return ordered.first { $0.startHour > hour } ?? ordered[0]
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
                if visibleWallpapers.isEmpty {
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
        let selected = inspected?.id == wallpaper.id
        return Button { model.select(wallpaper) } label: {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail(wallpaper.url, radius: 12)
                HStack(spacing: 8) {
                    IconTile(symbol: WallpaperPalette.categorySymbol(wallpaper.category),
                             color: WallpaperPalette.categoryColor(wallpaper.category), size: 20)
                    Text(displayTitle(wallpaper))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Pill(text: categoryTitle(wallpaper.category),
                         color: WallpaperPalette.categoryColor(wallpaper.category), fontSize: 10)
                        .fixedSize()
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
                }
            }
            .padding(10)
            .wallpaperCard(selected: selected)
            .contentShape(RoundedRectangle(cornerRadius: 16))
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

    // MARK: - Overview

    private func overview(now: Date) -> some View {
        let shares = categoryShares(now: now)
        let todayTotal = shares.reduce(0) { $0 + $1.today }
        var facts: [String] = []
        if todayTotal > 0 { facts.append(L("今天新增 \(todayTotal) 張")) }
        if model.isDynamicActive {
            let next = nextPhase(after: now)
            facts.append(L("下次切換 \(next.time) \(next.title)"))
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
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
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
            let next = nextPhase(after: now)
            statusCardBody(tone: .green, symbol: "checkmark",
                           title: L("日夜模式已啟用"),
                           detail: L("現在是\(current.title)，\(next.time) 換\(next.title)。")) {
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
            IconTile(symbol: symbol, color: color, size: 44)
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
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(0.3)))
    }

    // MARK: - 浮動操作列

    private var floatingBar: some View {
        HStack(spacing: 14) {
            if isDynamic {
                VStack(alignment: .leading, spacing: 1) {
                    Text("日夜桌布").font(.system(size: 13, weight: .semibold))
                    Text("4 個時段 · \(DynamicScene.resolution)")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(WallpaperPalette.secondaryText)
                }
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
                    Task { await model.activateDynamic() }
                } else if let wallpaper = inspected {
                    Task { await model.apply(wallpaper) }
                }
            }
            .buttonStyle(PrimaryCapsuleStyle())
            .disabled(model.isApplying || (isDynamic ? !DynamicScene.hasExport : inspected == nil))
        }
        .padding(.leading, 20).padding(.trailing, 7).padding(.vertical, 7)
        .background(FloatingBarBackground())
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.12), radius: 18, y: 6)
    }

    // MARK: - 動態桌布

    private var dynamicGallery: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let current = previewPhase ?? DynamicPhase.current(at: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            IconTile(symbol: "wand.and.rays", color: WallpaperSection.dynamic.color, size: 28)
                            Text("生成自己的日夜桌布").font(.system(size: 17, weight: .semibold))
                        }
                        TextField("描述同一個場景", text: $scenePrompt, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                        Text("先生成白天，再參考同一張原圖編修清晨、黃昏、夜晚；原圖保留，成品為 6144 × 3456 重採樣。")
                            .font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.isGenerating {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(model.generationProgress)
                                Spacer()
                                Button("取消生成") { model.cancelGeneration() }.buttonStyle(SecondaryCapsuleStyle())
                            }
                        } else {
                            Button("生成四時段 6K") { model.startDynamicGeneration(prompt: scenePrompt) }
                                .buttonStyle(PrimaryCapsuleStyle())
                                .disabled(scenePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(18)
                    .wallpaperCard()
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(DynamicScene.title)
                            .font(.system(size: 22, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .help(DynamicScene.title)
                        Pill(text: L("4 個時段"), color: WallpaperSection.dynamic.color)
                            .fixedSize()
                        Spacer(minLength: 8)
                        Picker("預覽", selection: $previewPhase) {
                            Text("目前時間").tag(Optional<DynamicPhase>.none)
                            ForEach(DynamicPhase.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        .fixedSize()
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(DynamicPhase.allCases.filter {
                            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
                            DynamicScene.title.localizedCaseInsensitiveContains(search)
                        }) { phase in
                            Button { previewPhase = phase } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    thumbnail(DynamicScene.imageURL(phase), radius: 12)
                                    HStack(spacing: 8) {
                                        IconTile(symbol: phase.symbol, color: WallpaperSection.dynamic.color, size: 20)
                                        Text(phase.title).font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                        Text(phase.time).font(.caption).monospacedDigit().foregroundStyle(WallpaperPalette.secondaryText)
                                    }
                                }
                                .padding(10)
                                .wallpaperCard(selected: current == phase)
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain).accessibilityLabel("預覽\(phase.title) \(phase.time)")
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, floatingClearance)
            }
        }
    }

    // MARK: - 檢視器

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isDynamic {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let phase = previewPhase ?? DynamicPhase.current(at: context.date)
                        VStack(alignment: .leading, spacing: 8) {
                            thumbnail(DynamicScene.imageURL(phase), radius: 12)
                            Text(DynamicScene.title).font(.headline).lineLimit(2)
                            Text("\(phase.title) · \(phase.time) 起").font(.caption).monospacedDigit()
                                .foregroundStyle(WallpaperPalette.secondaryText)
                        }
                    }
                    infoCard(title: "圖片") {
                        infoRow("解析度", DynamicScene.resolution)
                        infoRow("格式", L("HEIC · 4 個時段"))
                        infoRow("切換方式", L("App 背景時段排程"))
                        HStack(spacing: 6) {
                            Circle().fill(model.isDynamicActive ? WallpaperPalette.green : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(model.isDynamicActive ? "日夜模式已啟用，一般輪換暫停" : "設定後由背景自動切換時段")
                                .font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
                        }
                    }
                    infoCard(title: "桌面") { displayPicker }
                    Button("匯出 HEIC…", systemImage: "square.and.arrow.up") { exportDynamic() }
                        .buttonStyle(SecondaryCapsuleStyle())
                        .disabled(!DynamicScene.hasExport)
                } else if let wallpaper = inspected {
                    thumbnail(wallpaper.url, radius: 12)
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
                    infoCard(title: "圖片") {
                        infoRow("解析度", wallpaper.pixelText)
                        infoRow("檔案大小", wallpaper.sizeText)
                        infoRow("影像來源", wallpaper.origin.label)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("檔案").font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
                            Text(wallpaper.name).font(.caption).lineLimit(3).textSelection(.enabled)
                        }
                    }
                    infoCard(title: "桌面") { displayPicker }
                } else {
                    ContentUnavailableView("選取桌布", systemImage: "photo")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(16)
        }
        .background(WallpaperPalette.panel)
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

    private func thumbnail(_ url: URL, radius: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.06)
                if let cg = WallpaperLibrary.thumbnail(from: url, maxPixel: 900) {
                    Image(nsImage: NSImage(cgImage: cg, size: .zero))
                        .resizable().scaledToFill()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
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
                .font(.caption).foregroundStyle(WallpaperPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            Text("10 張會使用 10 種不同風格／主題。").font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
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
            }
            Section("每日生成") {
                Picker("張數", selection: Binding(get: { model.dailyMode }, set: { model.setDailyMode($0) })) {
                    ForEach(DailyScheduler.Mode.allCases) { Text($0.title).tag($0) }
                }
                Text("設定會保留。每天最多一批，使用 API 額度。要在關閉視窗後繼續，請到設定啟用背景服務；背景只輪換 6K 成品。")
                    .font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
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

    private func displayTitle(_ wallpaper: Wallpaper) -> String {
        index.titles[wallpaper.id] ?? wallpaper.url.deletingPathExtension().lastPathComponent
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

// MARK: - 顯示名稱（只影響顯示，不改檔名或資料）

/// 範本 id → 顯示名稱。字面常數讓 check.py 抽得到 key。
private func templateDisplayTitle(_ id: String) -> String? {
    switch id {
    case "nature-dawn": return L("破曉山稜")
    case "minimal-paper": return L("紙上遠山")
    case "abstract-flow": return L("流動光帶")
    case "illustration-dusk": return L("黃昏街角")
    case "cosmic-nebula": return L("星雲深處")
    case "botanical-macro": return L("葉脈微距")
    case "watercolor-meadow": return L("田園午後")
    case "architecture-arcade": return L("沙色拱廊")
    case "animation-coast": return L("海邊車站")
    case "gradient-tide": return L("潮汐漸層")
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
