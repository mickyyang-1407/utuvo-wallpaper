import SwiftUI

/// 第一次按「設為桌布」或捷徑執行失敗時：教使用者加入「UTUVO Set Wallpaper」捷徑，再套用一次。
struct ShortcutSetupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let reason: ShortcutSetupReason

    private var steps: [String] {
        [L("點下面「加入捷徑」，在分享選單選「捷徑」，再點「加入捷徑」。"),
         L("回到這裡，點「套用這張」。第一次「捷徑」會問能不能使用 UTUVO Wallpaper，選「允許」。"),
         L("之後在任何一張桌布按「設為桌布」，就會直接換好。")]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if case .failed(let text) = reason {
                        Label(text.map { L("捷徑沒有執行成功：\($0)") } ?? L("捷徑沒有執行成功。"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L("iOS 不允許 App 自己換桌布，要透過「捷徑」App。只要加入一次，之後按「設為桌布」就會直接套用。"))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
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
                    if let file = ApplyShortcut.bundledFile {
                        ShareLink(item: file) {
                            Label(L("加入捷徑"), systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button {
                        dismiss()
                        model.apply(nil, openURL: openURL)
                    } label: {
                        Label(L("套用這張"), systemImage: "iphone").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Text(L("也可以自己建：在「捷徑」新增一個捷徑，名字取「\(ApplyShortcut.name)」，加入「取得目前桌布」和「設定背景圖片」兩個動作，關掉「顯示預覽」。"))
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .background(CanvasBackground())
            .navigationTitle(L("設為桌布"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("關閉")) { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }
}

extension AppModel {
    /// 「設為桌布」：固定這張並執行捷徑；還沒設定好就跳出設定說明。
    /// `item` 為 nil＝已經固定好了，直接執行捷徑（設定說明裡的「套用這張」）。
    func apply(_ item: WallpaperItem?, openURL: OpenURLAction) {
        let url: URL?
        if let item { url = applyURL(for: item) } else { url = ApplyShortcut.runURL }
        run(url, openURL: openURL)
    }

    /// 「套用日夜桌布」：開日夜模式並立刻換成目前時段那張。
    func applyDynamic(openURL: OpenURLAction) {
        run(applyDynamicURL(), openURL: openURL)
    }

    private func run(_ url: URL?, openURL: OpenURLAction) {
        guard let url else { return }
        openURL(url) { [weak self] accepted in
            if !accepted { self?.shortcutSetup = .failed(L("找不到「捷徑」App。")) }
        }
    }
}
