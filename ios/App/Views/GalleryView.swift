import SwiftUI

struct GalleryView: View {
    @EnvironmentObject var model: AppModel
    @Binding var tab: RootTab
    @State private var filter: GalleryFilter = {
        if let raw = UserDefaults.standard.string(forKey: "UTUVOInitialFilter") {
            return GalleryFilter.allFilters.first { $0.id == raw } ?? .all
        }
        return .all
    }()
    @State private var selectedID: String?
    @State private var openedInitialDetail = false
    @State private var path: [WallpaperItem] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var shown: [WallpaperItem] { WallpaperLibrary.filter(model.items, by: filter, favorites: model.favorites) }
    private var selected: WallpaperItem? { model.items.first { $0.id == selectedID } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if filter == .all { overview }
                    filterBar
                    SectionTitle(title: filter.title, pill: L("\(shown.count) 張"), color: TileStyle.filter(filter).color)
                    if shown.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(shown) { item in card(item) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .defaultScrollAnchor(DebugLaunch.scrollToBottom ? .bottom : .top)
            .background(CanvasBackground())
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: WallpaperItem.self) { WallpaperDetailView(item: $0) }
            .onAppear {
                if selectedID == nil {
                    selectedID = model.pinnedID
                        ?? (UserDefaults.standard.bool(forKey: "UTUVOSelectFirst") ? model.items.first?.id : nil)
                }
                guard !openedInitialDetail, UserDefaults.standard.bool(forKey: "UTUVOOpenFirstDetail"),
                      let first = model.items.first else { return }
                openedInitialDetail = true
                path = [first]
            }
        }
    }

    // MARK: Overview

    private var overview: some View {
        let now = Date()
        let segments = OverviewFacts.segments(items: model.items, now: now)
        let total = model.items.count
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("UTUVO Wallpaper 為你準備了")).font(.system(size: 17)).foregroundStyle(.secondary)
                Text(L("\(total) 張")).font(.system(size: 52, weight: .bold)).monospacedDigit().tracking(-1)
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(facts(now: now)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            distributionBar(segments, total: total)
            Label(L("實心是今天新的，斜線是之前的。點一段可打開該分類。"), systemImage: "hand.point.up.left")
                .font(.footnote).foregroundStyle(.secondary)
            statusCard(now: now)
        }
    }

    private func facts(now: Date) -> String {
        var parts = [L("今天新增 \(OverviewFacts.todayNew(items: model.items, now: now)) 張")]
        if model.dynamicEnabled {
            let next = OverviewFacts.nextPhase(after: now)
            parts.append(L("下次切換 \(next.time) \(next.phase.title)"))
        } else if model.pinnedID != nil {
            parts.append(L("已釘選目前桌布"))
        } else {
            parts.append(model.favoritesOnly ? L("輪換收藏") : L("輪換全部"))
        }
        return parts.joined(separator: " · ")
    }

    private func distributionBar(_ segments: [CategorySegment], total: Int) -> some View {
        GeometryReader { geo in
            let spacing: CGFloat = 6
            let inner = geo.size.width - 12 - spacing * CGFloat(max(segments.count - 1, 0))
            HStack(spacing: spacing) {
                ForEach(segments) { seg in
                    let width = max(inner * CGFloat(seg.total) / CGFloat(max(total, 1)), 10)
                    let color = TileStyle.category(seg.category).color
                    Button { filter = .category(seg.category) } label: {
                        HStack(spacing: 0) {
                            if seg.newCount > 0 {
                                color.frame(width: width * CGFloat(seg.newCount) / CGFloat(seg.total))
                            }
                            if seg.oldCount > 0 { StripedFill(color: color) }
                        }
                        .frame(width: width)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(WallpaperCategory.title(seg.category)) \(seg.total)")
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.trackFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.cardStroke, lineWidth: 1))
    }

    private enum Tone { case good, warn, info }

    private func statusCard(now: Date) -> some View {
        let tone: Tone, symbol: String, title: String, detail: String, button: String, target: RootTab
        if let live = model.liveStatus {
            tone = live.ok ? .good : .warn; symbol = live.ok ? "checkmark" : "exclamationmark"
            title = L("單張實測"); detail = live.text; button = L("設定"); target = .settings
        } else if let error = model.dailyError {
            tone = .warn; symbol = "exclamationmark"; title = L("今天的自動生成沒有完成"); detail = error
            button = L("設定"); target = .settings
        } else if model.dynamicEnabled {
            let current = DayPhase.current(at: now)
            let next = OverviewFacts.nextPhase(after: now)
            tone = .good; symbol = "checkmark"; title = L("日夜模式已啟用")
            detail = L("現在是\(current.title)，\(next.time) 換\(next.phase.title)。")
            button = L("查看"); target = .dynamic
        } else if model.dailyEnabled {
            tone = .good; symbol = "checkmark"; title = L("每日自動生成已開啟")
            if let p = model.dailyProgress {
                detail = model.isDailyRunning ? L("今日批次生成中：\(p.done)／\(p.total)") : L("今天已完成 \(p.done)／\(p.total) 張。")
            } else {
                detail = L("今天的 10 張會在打開 App 或夜間補做。")
            }
            button = L("設定"); target = .settings
        } else {
            tone = .info; symbol = "sparkles"; title = L("每日自動生成未開啟")
            detail = L("用自己的 OpenAI API key，每天補 10 張不同主題的新桌布。")
            button = L("設定"); target = .settings
        }
        let color: Color = tone == .good ? Palette.green : tone == .warn ? Palette.orange : Palette.accent
        return HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(button) { tab = target }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(color.opacity(0.30), lineWidth: 1))
    }

    // MARK: 篩選

    private func count(_ f: GalleryFilter) -> Int { WallpaperLibrary.filter(model.items, by: f, favorites: model.favorites).count }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GalleryFilter.allFilters) { f in
                    let style = TileStyle.filter(f)
                    Button { filter = f } label: {
                        HStack(spacing: 7) {
                            IconTile(symbol: style.symbol, color: style.color, size: 22)
                            Text(f.title).font(.subheadline.weight(.semibold))
                            Text("\(count(f))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                        .background(Capsule().fill(filter == f ? Palette.accent.opacity(0.18) : Palette.cardFill))
                        .overlay(Capsule().stroke(filter == f ? Palette.accent : Palette.cardStroke, lineWidth: filter == f ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            IconTile(symbol: TileStyle.filter(filter).symbol, color: TileStyle.filter(filter).color, size: 44)
            Text(filter == .favorites ? L("還沒有收藏。打開一張桌布，點愛心收藏。") : L("這個分類還沒有桌布。開啟每日自動生成後會慢慢補齊。"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(28).card()
    }

    // MARK: 卡片

    private func resolution(_ item: WallpaperItem) -> String {
        let size = item.isDemo ? DeviceScreen.nativePixels : (ImageProcessing.pixelSize(at: item.url) ?? DeviceScreen.nativePixels)
        return "\(Int(size.width))×\(Int(size.height))"
    }

    private func card(_ item: WallpaperItem) -> some View {
        let style = TileStyle.category(item.category)
        let isSelected = selectedID == item.id
        return VStack(alignment: .leading, spacing: 8) {
            ThumbnailView(url: item.url)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        if model.pinnedID == item.id { badge("pin.fill", Palette.accent) }
                        if model.favorites.contains(item.id) { badge("heart.fill", TileStyle.favorites.color) }
                    }.padding(8)
                }
            HStack(alignment: .top, spacing: 6) {
                IconTile(symbol: style.symbol, color: style.color, size: 18)
                Text(model.title(for: item)).font(.caption.weight(.semibold))
                    .lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Pill(text: item.isDemo ? L("示範圖") : WallpaperCategory.title(item.category), color: style.color, size: 11)
                Spacer(minLength: 2)
                Text(resolution(item)).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .padding(8)
        .card()
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(isSelected ? Palette.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { path = [item] } else { selectedID = item.id }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(L("點一下選取，再點一下打開"))
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.caption2).foregroundStyle(.white)
            .padding(5).background(Circle().fill(color))
    }

    // MARK: 浮動操作列

    private var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                if let item = selected {
                    Text(L("已選 1 張")).font(.subheadline.weight(.semibold))
                    Text(verbatim: "\(resolution(item)) · \(WallpaperCategory.title(item.category))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                } else {
                    Text(L("未選取")).font(.subheadline.weight(.semibold))
                    Text(L("點一張桌布來選取")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 6)
            Spacer(minLength: 4)
            if let item = selected {
                Button { path = [item] } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel(L("打開"))
            }
            Button {
                if let item = selected { model.togglePin(item) }
            } label: {
                Text(selected.map { model.pinnedID == $0.id } == true ? L("已設為目前桌布") : L("設為目前桌布"))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selected == nil)
        }
        .padding(6)
        .padding(.leading, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Palette.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
        // Fade the scrolling cards out behind the action bar and tab bar so no
        // half-cut caption shows between the two floating bars.
        .background(alignment: .bottom) {
            LinearGradient(stops: [.init(color: Palette.canvas.opacity(0), location: 0),
                                   .init(color: Palette.canvas.opacity(0.92), location: 0.45),
                                   .init(color: Palette.canvas, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }
}
