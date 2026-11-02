import SwiftUI

/// 「產生桌布」面板（比照 Mac 的產生桌布彈窗）：張數、分類、自己的 Prompt、AI 靈感。
/// 關掉面板生成照樣進行，進度也顯示在圖庫的狀態卡。
struct GenerateSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var openSettings: () -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("number", Color(hex: 0x0A84FF)) {
                        Stepper(value: $model.manualCount, in: 1...10) {
                            HStack {
                                Text(L("張數"))
                                Spacer()
                                Text(L("\(model.manualCount) 張")).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    row("paintpalette", Color(hex: 0xBF5AF2)) {
                        Text(L("分類"))
                        Spacer()
                        Menu {
                            Button(L("全部分類")) { model.manualRecipe.styles = [] }
                            Divider()
                            ForEach(DailyRecipe.categories, id: \.self) { category in
                                Toggle(WallpaperCategory.title(category), isOn: Binding(
                                    get: { model.manualRecipe.categories.contains(category) },
                                    set: { model.manualRecipe.setCategory(category, on: $0) }))
                            }
                        } label: {
                            let selected = model.manualRecipe.categories
                            Text(selected.isEmpty ? L("全部分類")
                                 : selected.count == 1 ? WallpaperCategory.title(selected[0]) : L("\(selected.count) 個分類"))
                        }
                    }
                    row("lightbulb", Color(hex: 0xFFD60A)) {
                        TextField(L("自己的 Prompt（選填）"), text: Binding(
                            get: { model.manualRecipe.idea },
                            set: { model.manualRecipe.idea = String($0.prefix(DailyRecipe.ideaLimit)) }),
                                  prompt: Text(L("例如：台北的老公寓陽台")), axis: .vertical)
                            .lineLimit(1...3)
                        InspirationButton {
                            model.manualRecipe.idea = PromptInspiration.pick(categories: model.manualRecipe.categories,
                                                                             current: model.manualRecipe.idea, chinese: isChineseUI)
                        }
                    }
                } footer: {
                    Text(L("每張換主題、配色、光線與構圖；寫了自己的 Prompt 就每張都畫它。純色與漸層在手機上直接畫，免費、不用 API key；其他每張是一次 OpenAI 請求，費用算在你的帳號。"))
                }

                Section {
                    if let p = model.manualProgress {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(L("已產生 \(p.done)／\(p.total) 張")).font(.subheadline.weight(.semibold)).monospacedDigit()
                                Spacer()
                                Button(L("取消"), role: .destructive) { model.cancelManual() }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                            ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).tint(Palette.accent)
                            Text(L("可以關掉這個面板，生成會繼續。")).font(.footnote).foregroundStyle(.secondary)
                        }
                        .listRowBackground(Palette.cardFill)
                    } else if model.manualNeedsKey {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("要先在設定存好 OpenAI API key。只選純色或漸層的話不用 key。"))
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button(L("前往設定")) { dismiss(); openSettings() }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                        .listRowBackground(Palette.cardFill)
                    } else {
                        Button { model.generateNow() } label: {
                            Label(L("產生 \(model.manualCount) 張"), systemImage: "sparkles").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    if let done = model.manualDone {
                        Label(L("完成 \(done) 張，已加入圖庫。"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.green).listRowBackground(Palette.cardFill)
                    }
                    if let error = model.manualError {
                        Text(error).font(.footnote).foregroundStyle(Palette.orange).listRowBackground(Palette.cardFill)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CanvasBackground())
            .navigationTitle(L("產生桌布"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } }
            }
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
