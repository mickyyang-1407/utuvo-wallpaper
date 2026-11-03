import SwiftUI

@main
struct UTUVOWallpaperApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var location = LocationFetcher()

    init() {
        _ = AppLanguage.atLaunch
        BackgroundScheduler.register()
        // 一啟動就接上背景 session：上次啟動留下、已經沒人在等的生圖請求馬上取消。
        _ = BackgroundTransfer.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear {
                    DeviceScreen.refresh()
                    model.reload()
                    model.runDailyIfNeeded()
                    model.runDynamicAutoIfNeeded()
                    location.refreshIfAuthorized()
                    #if DEBUG
                    model.startLiveOneIfRequested()
                    #endif
                }
        }
    }
}
