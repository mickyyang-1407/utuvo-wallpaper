import AppKit
import Carbon.HIToolbox

/// 選單列、全域快捷鍵、捷徑網址共用的指令。
enum WallpaperCommand: String, CaseIterable, Sendable {
    case next, previous, favorite, pause, resume, togglePause = "toggle-pause"

    static let scheme = "utuvo-wallpaper"

    /// `utuvo-wallpaper://next`（或 `utuvo-wallpaper:next`）；大小寫不拘，其他網址回 nil。
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let raw = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        self.init(rawValue: raw)
    }

    @MainActor
    func perform(on model: AppModel) async {
        switch self {
        case .next: await model.skipToNext()
        case .previous: await model.applyPrevious()
        case .favorite: model.toggleFavoriteForCurrentDesktop()
        case .pause: model.setRotationPaused(true)
        case .resume: model.setRotationPaused(false)
        case .togglePause: model.setRotationPaused(!model.isRotationPaused)
        }
    }
}

enum MenuBarPreferences {
    static let iconKey = "menuBar.enabled"
    static let hotKeysKey = "hotKeys.enabled"
    static var showsIcon: Bool { UserDefaults.standard.object(forKey: iconKey) as? Bool ?? true }
    static var hotKeysEnabled: Bool { UserDefaults.standard.object(forKey: hotKeysKey) as? Bool ?? true }
    static let changed = Notification.Name("com.utuvo.wallpaper-lab.menu-bar-preferences")
}

/// 選單列小圖示。選單每次打開時重建，暫停狀態與日夜模式永遠是最新的。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let model: AppModel
    private let openWindow: () -> Void

    init(model: AppModel, openWindow: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
        super.init()
    }

    func refresh() {
        if MenuBarPreferences.showsIcon {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "UTUVO Wallpaper")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let dynamic = model.isDynamicActive
        let arrows = NSEvent.ModifierFlags([.control, .option, .command])
        add(menu, L("下一張桌布"), #selector(next), key: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: arrows, enabled: !dynamic)
        add(menu, L("上一張桌布"), #selector(previous), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: arrows, enabled: !dynamic)
        add(menu, L("收藏／取消收藏目前桌布"), #selector(favorite), key: "f", modifiers: arrows)
        add(menu, model.isRotationPaused ? L("繼續輪換") : L("暫停輪換"), #selector(togglePause), key: "p", modifiers: arrows)
        if dynamic {
            let note = NSMenuItem(title: L("日夜模式啟用中：\(DynamicPhase.current(at: Date()).title)"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        add(menu, L("開啟 UTUVO Wallpaper"), #selector(open), key: "")
        add(menu, L("結束 UTUVO Wallpaper"), #selector(quit), key: "")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String,
                     modifiers: NSEvent.ModifierFlags = [], enabled: Bool = true) {
        let entry = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = self
        entry.isEnabled = enabled
        menu.addItem(entry)
    }

    @objc private func next() { run(.next) }
    @objc private func previous() { run(.previous) }
    @objc private func favorite() { run(.favorite) }
    @objc private func togglePause() { run(.togglePause) }
    @objc private func open() { openWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func run(_ command: WallpaperCommand) {
        Task { await command.perform(on: model) }
    }
}

/// 全域快捷鍵（Carbon RegisterEventHotKey，不需要輔助使用權限）：⌃⌥⌘→ 下一張、⌃⌥⌘← 上一張、⌃⌥⌘F 收藏、⌃⌥⌘P 暫停。
@MainActor
final class HotKeyCenter {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    fileprivate static var onCommand: ((WallpaperCommand) -> Void)?
    fileprivate static let commands: [UInt32: WallpaperCommand] = [1: .next, 2: .previous, 3: .favorite, 4: .togglePause]

    func refresh(onCommand: @escaping (WallpaperCommand) -> Void) {
        unregister()
        guard MenuBarPreferences.hotKeysEnabled else { return }
        Self.onCommand = onCommand
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let command = HotKeyCenter.commands[id.id] {
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.onCommand?(command) } }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        let keys: [(UInt32, Int)] = [(1, kVK_RightArrow), (2, kVK_LeftArrow), (3, kVK_ANSI_F), (4, kVK_ANSI_P)]
        for (id, key) in keys {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x5554_5657), id: id) // 'UTVW'
            if RegisterEventHotKey(UInt32(key), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    /// 實際註冊成功幾組（被別的 App 佔走的組合會失敗）。
    var registeredCount: Int { refs.count }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
