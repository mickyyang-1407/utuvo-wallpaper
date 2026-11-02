import SwiftUI

struct DynamicView: View {
    @EnvironmentObject var model: AppModel
    @State private var prompt = ""
    @FocusState private var focused: Bool

    private let phaseColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    modeCard
                    SectionTitle(title: L("四時段預覽"), pill: L("4 張"), color: TileStyle.dynamic.color)
                    LazyVGrid(columns: phaseColumns, spacing: 10) {
                        ForEach(DayPhase.allCases) { phase in phaseCell(phase) }
                    }
                    SectionTitle(title: L("新場景"), pill: nil)
                    newSceneCard
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(DebugLaunch.scrollToBottom ? .bottom : .top)
            .background(CanvasBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        let now = Date()
        let current = DayPhase.current(at: now)
        let next = OverviewFacts.nextPhase(after: now)
        return VStack(alignment: .leading, spacing: 2) {
            Text(L("日夜")).font(.system(size: 17)).foregroundStyle(.secondary)
            Text(current.title).font(.system(size: 52, weight: .bold)).tracking(-1)
            Text(L("下次切換 \(next.time) \(next.phase.title)")).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var modeCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: TileStyle.dynamic.symbol, color: TileStyle.dynamic.color)
                Toggle(L("啟用日夜模式"), isOn: $model.dynamicEnabled).tint(Palette.green)
            }
            .padding(.vertical, 10)
            Divider().padding(.leading, 42)
            HStack(spacing: 12) {
                IconTile(symbol: "mountain.2.fill", color: TileStyle.all.color)
                Text(L("場景"))
                Spacer()
                Menu {
                    Picker(L("場景"), selection: Binding(get: { model.dynamicSceneID }, set: { model.selectScene($0) })) {
                        Text(L("示範 · 山間四時")).tag("demo")
                        if let scene = model.publishedScene {
                            Text(scene.prompt).tag(scene.id)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(sceneName).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .foregroundStyle(Palette.accent)
                }
            }
            .padding(.vertical, 6)
            Text(L("啟用後，「取得目前桌布」會依時段回傳：\(DayPhase.dawn.time) 清晨、\(DayPhase.day.time) 白天、\(DayPhase.dusk.time) 黃昏、\(DayPhase.night.time) 夜晚。"))
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 14)
        .card()
    }

    private var sceneName: String {
        if model.dynamicSceneID != "demo", let scene = model.publishedScene, scene.id == model.dynamicSceneID { return scene.prompt }
        return L("示範 · 山間四時")
    }

    private var newSceneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("場景來源"))
                Spacer()
                Picker(L("場景來源"), selection: $model.dynamicAutoFrequency) {
                    ForEach(DynamicAutoFrequency.allCases) { Text($0.title).tag($0) }
                }
                .tint(Palette.accent)
            }
            if model.dynamicAutoFrequency == .off {
                TextField(L("例如：湖邊的小木屋與松林"), text: $prompt, axis: .vertical)
                    .lineLimit(2...4).focused($focused)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.trackFill))
            } else {
                Text(model.dynamicAutoFrequency == .daily
                     ? L("AI 每天依季節挑一個新場景，打開 App 時自動生成四時段，完成後直接換上。")
                     : L("AI 每週依季節挑一個新場景，打開 App 時自動生成四時段，完成後直接換上。"))
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text(L("每組 4 次圖片生成，使用你的 OpenAI API 額度。"))
                    .font(.footnote).foregroundStyle(.secondary)
                if let state = model.dynamicAutoState {
                    Text(state.completed ? L("上一組：\(state.prompt)")
                         : state.attempts >= DynamicAutoState.maxAttempts ? L("這一期未完成：\(state.prompt)")
                         : L("進行中：\(state.prompt)"))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let step = model.sceneProgress {
                ProgressView(value: Double(step), total: 4) {
                    Text(L("生成中：\(step)／4")).font(.footnote).monospacedDigit()
                }
                .tint(Palette.accent)
            }
            if model.dynamicAutoFrequency == .off {
                Button {
                    focused = false
                    let text = prompt
                    Task { await model.generateScene(text) }
                } label: {
                    Label(L("生成日夜桌布（4 張）"), systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sceneProgress != nil)
            } else {
                Button {
                    Task { await model.generateAutoSceneNow() }
                } label: {
                    Label(L("現在用 AI 生成一組"), systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.sceneProgress != nil)
            }
            if let error = model.sceneError {
                Text(error).font(.footnote).foregroundStyle(Palette.orange)
            }
            Text(L("先生成白天，再用同一張白天圖換光線做出清晨、黃昏、夜晚，構圖不變。四張全部完成才會出現在場景清單。需要自己的 OpenAI API key。"))
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .card()
    }

    private func phaseCell(_ phase: DayPhase) -> some View {
        let url = try? WallpaperLibrary.scenePhaseJPEG(sceneID: model.dynamicSceneID, phase: phase,
                                                       paths: model.paths, target: DeviceScreen.nativePixels)
        let isNow = DayPhase.current(at: Date()) == phase
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if let url { ThumbnailView(url: url, maxPixel: 600) } else { Palette.trackFill }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 6) {
                IconTile(symbol: phase.symbol, color: TileStyle.dynamic.color, size: 18)
                Text(phase.title).font(.caption.weight(.semibold))
                Spacer(minLength: 2)
                if isNow { Pill(text: L("現在"), color: Palette.green, size: 11) }
                Text(phase.time).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(8)
        .card()
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(isNow ? Palette.accent : .clear, lineWidth: 2))
    }
}
