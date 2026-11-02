import Foundation
import AppKit
import SwiftUI

// MARK: - App 模式

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var model: AppModel?
    private var menuBar: MenuBarController?
    private let hotKeys = HotKeyCenter()
    /// 由網址啟動時，網址可能比 didFinishLaunching 早到；先排著。
    private var pendingCommands: [WallpaperCommand] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 舊版 LaunchAgent 跑主 App 本體：改指到背景助手（launchctl 在背景執行，不擋視窗）。
        DispatchQueue.global(qos: .utility).async { BackgroundService.migrateToAgentIfNeeded() }
        let model = AppModel()
        self.model = model
        let content = NSHostingController(rootView: ContentView(model: model))
        let window = NSWindow(contentViewController: content)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = LabPaths.appName
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.center()
        window.minSize = NSSize(width: 1000, height: 660)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let settingsItem = NSMenuItem(title: L("設定…"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: L("結束 UTUVO Wallpaper"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let editItem = NSMenuItem(title: L("編輯"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("編輯"))
        editMenu.addItem(withTitle: L("剪下"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷貝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("貼上"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全選"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        menuBar = MenuBarController(model: model) { [weak self] in self?.showWindow() }
        refreshMenuBarAndHotKeys()
        NotificationCenter.default.addObserver(forName: MenuBarPreferences.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenuBarAndHotKeys() }
        }
        let queued = pendingCommands
        pendingCommands = []
        for command in queued { Task { await command.perform(on: model) } }
    }

    private func refreshMenuBarAndHotKeys() {
        menuBar?.refresh()
        hotKeys.refresh { [weak self] command in
            guard let model = self?.model else { return }
            Task { await command.perform(on: model) }
        }
    }

    /// 選單列圖示開著時，關掉視窗只是收到選單列（Dock 圖示也收起來），快捷鍵照常可用。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MenuBarPreferences.showsIcon }

    func windowWillClose(_ notification: Notification) {
        if MenuBarPreferences.showsIcon { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for command in urls.compactMap(WallpaperCommand.init(url:)) {
            if let model { Task { await command.perform(on: model) } } else { pendingCommands.append(command) }
        }
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openSettings(_ sender: Any?) {
        NotificationCenter.default.post(name: .wallpaperOpenSettings, object: nil)
    }
}

// MARK: - 進入點

let cliArguments = Array(CommandLine.arguments.dropFirst())

// 背景助手：介面語言跟主 App 的選擇（要在第一次查表前）。
AppDefaults.adoptHostLanguage()

if let mode = CLI.parse(cliArguments) {
    // 背景排程寫給 GUI 顯示的狀態要跟系統語言；其餘 CLI 與自我測試固定繁中原文。
    if case .backgroundTick = mode {} else { Localization.sourceOnly = true }
    // CLI 模式：跑完直接結束，不開視窗。
    Task { @MainActor in
        let code = await CLI.run(mode)
        exit(code)
    }
    // 讓 main actor 有機會執行（main queue 由主 run loop 服務）。
    RunLoop.main.run()
} else {
    _ = AppLanguage.atLaunch
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
