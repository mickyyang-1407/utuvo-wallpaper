import SwiftUI

@main
struct UTUVOWallpaperApp: App {
    @StateObject private var model = AppModel()

    init() {
        _ = AppLanguage.atLaunch
        BackgroundScheduler.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear {
                    DeviceScreen.refresh()
                    model.reload()
                    model.runDailyIfNeeded()
                    #if DEBUG
                    model.startLiveOneIfRequested()
                    #endif
                }
        }
    }
}
