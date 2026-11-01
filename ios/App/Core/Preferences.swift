import Foundation

/// UserDefaults 裡的使用者選項（收藏、釘選、輪換、日夜模式）。
struct Preferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var favorites: Set<String> {
        get { Set(defaults.stringArray(forKey: "favorites") ?? []) }
        nonmutating set { defaults.set(Array(newValue).sorted(), forKey: "favorites") }
    }
    var pinnedID: String? {
        get { defaults.string(forKey: "pinnedID") }
        nonmutating set { defaults.set(newValue, forKey: "pinnedID") }
    }
    var rotation: RotationState {
        get { RotationState(cursor: defaults.integer(forKey: "rotationCursor"),
                            lastServedSlot: defaults.object(forKey: "rotationLastSlot") as? Int) }
        nonmutating set {
            defaults.set(newValue.cursor, forKey: "rotationCursor")
            defaults.set(newValue.lastServedSlot, forKey: "rotationLastSlot")
        }
    }
    var favoritesOnly: Bool {
        get { defaults.bool(forKey: "favoritesOnly") }
        nonmutating set { defaults.set(newValue, forKey: "favoritesOnly") }
    }
    var dailyEnabled: Bool {
        get { defaults.bool(forKey: "dailyEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "dailyEnabled") }
    }
    var dynamicEnabled: Bool {
        get { defaults.bool(forKey: "dynamicEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "dynamicEnabled") }
    }
    /// "demo" 或已發布場景 id。
    var dynamicSceneID: String {
        get { defaults.string(forKey: "dynamicSceneID") ?? "demo" }
        nonmutating set { defaults.set(newValue, forKey: "dynamicSceneID") }
    }
}
