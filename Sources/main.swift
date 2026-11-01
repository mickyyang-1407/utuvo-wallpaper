import Foundation
import AppKit
import SwiftUI

// MARK: - App 模式

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSHostingController(rootView: ContentView())
        let window = NSWindow(contentViewController: content)
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc private func openSettings(_ sender: Any?) {
        NotificationCenter.default.post(name: .wallpaperOpenSettings, object: nil)
    }
}

// MARK: - 進入點

let cliArguments = Array(CommandLine.arguments.dropFirst())

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
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
