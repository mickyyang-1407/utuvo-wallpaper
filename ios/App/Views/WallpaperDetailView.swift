import SwiftUI

struct WallpaperDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// 打開時那一頁的清單（圖庫目前的篩選結果），左右滑動換上一張／下一張。
    let items: [WallpaperItem]
    var onPageChange: (String) -> Void = { _ in }
    @State private var currentID: String?
    @State private var shareURL: URL?
    @State private var confirmDelete = false

    init(items: [WallpaperItem], startID: String, onPageChange: @escaping (String) -> Void = { _ in }) {
        self.items = items
        self.onPageChange = onPageChange
        _currentID = State(initialValue: startID)
    }

    /// 已被刪掉的不再出現。
    private var pages: [WallpaperItem] {
        let alive = Set(model.items.map(\.id))
        return items.filter { alive.contains($0.id) }
    }
    private var item: WallpaperItem {
        pages.first { $0.id == currentID } ?? pages.first ?? items[0]
    }
    private var pageIndex: Int { pages.firstIndex { $0.id == item.id } ?? 0 }

    private var isPinned: Bool { model.pinnedID == item.id }
    private var isFavorite: Bool { model.favorites.contains(item.id) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentID) {
                ForEach(pages) { page in
                    ThumbnailView(url: page.url, maxPixel: 3000).ignoresSafeArea()
                        .tag(Optional(page.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .accessibilityIdentifier("detailPager")
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    roundButton(isFavorite ? "heart.fill" : "heart", isFavorite ? L("已收藏") : L("收藏"),
                                tint: isFavorite ? TileStyle.favorites.color : .primary) { model.toggleFavorite(item) }
                    roundButton(isPinned ? "pin.fill" : "pin", isPinned ? L("已固定") : L("固定這張"),
                                tint: isPinned ? Palette.green : .primary) { model.togglePin(item) }
                    roundButton("square.and.arrow.down", L("儲存到照片")) { Task { await model.saveToPhotos(item) } }
                    if let shareURL {
                        ShareLink(item: shareURL) { roundLabel("square.and.arrow.up", L("分享"), tint: .primary) }
                            .buttonStyle(.plain)
                    }
                    if !item.isDemo {
                        roundButton("trash", L("刪除"), tint: .red) { confirmDelete = true }
                    }
                }
                actionBar
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .navigationTitle(model.title(for: item))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .confirmationDialog(L("刪除這張桌布？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("刪除"), role: .destructive) {
                let gone = item
                let next = WallpaperLibrary.neighborID(of: gone.id, in: pages.map(\.id))
                model.delete(gone)
                if let next { currentID = next } else { dismiss() }
            }
        }
        .task(id: item.id) {
            shareURL = nil
            shareURL = model.deviceFile(for: item)
        }
        .onChange(of: currentID) { _, id in if let id { onPageChange(id) } }
    }

    private var actionBar: some View {
        let style = TileStyle.category(item.category)
        let size = DeviceScreen.nativePixels
        return HStack(spacing: 10) {
            IconTile(symbol: style.symbol, color: style.color, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.isDemo ? L("示範圖") : WallpaperCategory.title(item.category))
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    if pages.count > 1 {
                        Text(verbatim: "\(pageIndex + 1)／\(pages.count)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                    }
                }
                Text(verbatim: "\(Int(size.width))×\(Int(size.height))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.apply(item, openURL: openURL) } label: {
                Label(L("設為桌布"), systemImage: "iphone").lineLimit(1).fixedSize()
            }
            .buttonStyle(PrimaryButtonStyle())
            .layoutPriority(1)
        }
        .padding(6).padding(.leading, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Palette.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    private func roundButton(_ symbol: String, _ title: String, tint: Color = .primary, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { roundLabel(symbol, title, tint: tint) }.buttonStyle(.plain)
    }

    private func roundLabel(_ symbol: String, _ title: String, tint: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 48, height: 48)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Palette.cardStroke, lineWidth: 1))
            .accessibilityLabel(title)
    }
}
