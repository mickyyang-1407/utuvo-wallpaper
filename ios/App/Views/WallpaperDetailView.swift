import SwiftUI

struct WallpaperDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let item: WallpaperItem
    @State private var shareURL: URL?
    @State private var confirmDelete = false

    private var isPinned: Bool { model.pinnedID == item.id }
    private var isFavorite: Bool { model.favorites.contains(item.id) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            ThumbnailView(url: item.url, maxPixel: 3000).ignoresSafeArea()
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
            Button(L("刪除"), role: .destructive) { model.delete(item); dismiss() }
        }
        .task { shareURL = model.deviceFile(for: item) }
    }

    private var actionBar: some View {
        let style = TileStyle.category(item.category)
        let size = DeviceScreen.nativePixels
        return HStack(spacing: 10) {
            IconTile(symbol: style.symbol, color: style.color, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.isDemo ? L("示範圖") : WallpaperCategory.title(item.category))
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
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
