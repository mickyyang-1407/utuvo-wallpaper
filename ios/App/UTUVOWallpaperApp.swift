import SwiftUI

@main
struct UTUVOWallpaperApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var location = LocationFetcher()

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
                    location.refreshIfAuthorized()
                    #if DEBUG
                    model.startLiveOneIfRequested()
                    #endif
                }
        }
    }
}
