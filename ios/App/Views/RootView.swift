import SwiftUI

enum RootTab: String, Hashable { case gallery, dynamic, settings }

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: RootTab = {
        switch UserDefaults.standard.string(forKey: "UTUVOInitialTab") {
        case "dynamic": return .dynamic
        case "settings": return .settings
        default: return .gallery
        }
    }()

    var body: some View {
        TabView(selection: $tab) {
            GalleryView(tab: $tab)
                .tabItem { Label(L("圖庫"), systemImage: "square.grid.2x2") }
                .tag(RootTab.gallery)
            DynamicView()
                .tabItem { Label(L("日夜"), systemImage: "sun.and.horizon") }
                .tag(RootTab.dynamic)
            SettingsView()
                .tabItem { Label(L("設定"), systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .tint(Palette.accent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                DeviceScreen.refresh()
                model.reload()
                model.runDailyIfNeeded()
            } else if phase == .background, model.dailyEnabled {
                BackgroundScheduler.schedule()
            }
        }
        .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(L("好")) { model.message = nil }
        }
    }
}
