import Foundation
import Darwin

/// 主 App 與背景助手（Contents/Helpers/UTUVO Wallpaper Agent.app）。
/// LaunchAgent 跑助手：主 App 本體在背景跑時，系統會把它當成「已開著的 App」，
/// 使用者點 App 只會切到那個沒有視窗的程序。
enum AppBundle {
    static let agentName = "UTUVO Wallpaper Agent.app"

    /// 主 App；在助手裡執行時往外找三層（Helpers → Contents → .app）。
    static var host: Bundle {
        let url = Bundle.main.bundleURL
        guard url.deletingLastPathComponent().lastPathComponent == "Helpers" else { return .main }
        return Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) ?? .main
    }

    static var isAgent: Bool { Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Helpers" }

    /// LaunchAgent 要跑的執行檔：有助手就用助手，沒有（舊的開發版）才退回主 App 本體。
    static func backgroundExecutable(hostBundleURL: URL = host.bundleURL,
                                     fileManager: FileManager = .default) -> URL? {
        let agent = hostBundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(agentName, isDirectory: true)
            .appendingPathComponent("Contents/MacOS/WallpaperLab")
        if fileManager.isExecutableFile(atPath: agent.path) { return agent }
        return Bundle(url: hostBundleURL)?.executableURL
    }
}

/// Per-user LaunchAgent management. Uses the public launchctl commands documented
/// by launchctl(1); command output is discarded rather than parsed or logged.
enum BackgroundService {
    static let enabledKey = "background.enabled"
    static let label = "com.utuvo.wallpaper-lab.background"

    private static var domain: String { "gui/\(getuid())" }
    private static var service: String { "\(domain)/\(label)" }
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(label + ".plist")
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func registrationPlist(executableURL: URL, dataDirectory: URL? = nil) throws -> Data {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              !executableURL.path.utf8.contains(0) else {
            throw BackgroundServiceError.invalidExecutable
        }
        var values: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path, "--background-tick"],
            "RunAtLoad": true,
            "StartInterval": 60,
            // launchd can defer the 60-second interval by minutes; phase boundaries
            // also get their own calendar wake so dusk/night switch on the minute.
            "StartCalendarInterval": DynamicPhase.allCases.map { ["Hour": $0.startHour, "Minute": 0] },
            "LimitLoadToSessionType": "Aqua"
        ]
        if let dataDirectory {
            guard dataDirectory.isFileURL, !dataDirectory.path.utf8.contains(0) else {
                throw BackgroundServiceError.invalidDataDirectory
            }
            values["EnvironmentVariables"] = ["UTUVO_WALLPAPER_DATA_DIR": dataDirectory.path]
        }
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    /// A downloaded App opened from the disk image or quarantine runs from a temporary
    /// path; a LaunchAgent pointing there stops working once that path disappears.
    static func isTemporaryLocation(_ executableURL: URL) -> Bool {
        let path = executableURL.standardizedFileURL.path
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
            || path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")
    }

    static func enable(executableURL: URL, defaults: UserDefaults = .standard) throws {
        var wrotePlist = false
        do {
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw BackgroundServiceError.invalidExecutable
            }
            guard !isTemporaryLocation(executableURL) else { throw BackgroundServiceError.notInstalled }
            let data = try registrationPlist(executableURL: executableURL, dataDirectory: LabPaths.deliveryRoot)
            do {
                try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: plistURL, options: .atomic)
                wrotePlist = true
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
            } catch {
                throw BackgroundServiceError.cannotWritePlist
            }
            try bootoutIfLoaded()
            defaults.set(true, forKey: enabledKey)
            defaults.synchronize()
            try requireSuccess(["enable", service], action: L("啟用"))
            try requireSuccess(["bootstrap", domain, plistURL.path], action: L("載入"))
        } catch {
            defaults.set(false, forKey: enabledKey)
            if wrotePlist { try? FileManager.default.removeItem(at: plistURL) }
            throw error
        }
    }

    static func disable(defaults: UserDefaults = .standard) throws {
        defaults.set(false, forKey: enabledKey)
        defaults.synchronize()
        var failure: Error?
        do { try bootoutIfLoaded() } catch { failure = error }
        do {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        } catch {
            if failure == nil { failure = BackgroundServiceError.cannotRemovePlist }
        }
        if let failure { throw failure }
    }

    /// LaunchAgent 目前跑哪個執行檔（讀不到回 nil）。
    static func registeredExecutablePath() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }

    /// 舊版把 LaunchAgent 指到主 App 本體；已開啟背景時改指到助手並重新載入。回傳是否有改。
    @discardableResult
    static func migrateToAgentIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(in: defaults), let expected = AppBundle.backgroundExecutable(),
              let current = registeredExecutablePath(),
              current != expected.path, !isTemporaryLocation(expected) else { return false }
        do { try enable(executableURL: expected, defaults: defaults); return true }
        catch { return false }
    }

    static func isLoaded() -> Bool {
        (try? runLaunchctl(["print", service])) == 0
    }

    private static func bootoutIfLoaded() throws {
        guard isLoaded() else { return }
        let status = try runLaunchctl(["bootout", service])
        // Another caller may already have unloaded this same job.
        if status != 0 && isLoaded() {
            throw BackgroundServiceError.commandFailed(action: L("停止"), status: status)
        }
    }

    private static func requireSuccess(_ arguments: [String], action: String) throws {
        let status = try runLaunchctl(arguments)
        guard status == 0 else {
            throw BackgroundServiceError.commandFailed(action: action, status: status)
        }
    }

    private static func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw BackgroundServiceError.commandUnavailable }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private enum BackgroundServiceError: LocalizedError {
    case invalidExecutable
    case notInstalled
    case invalidDataDirectory
    case cannotWritePlist
    case cannotRemovePlist
    case commandUnavailable
    case commandFailed(action: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidExecutable: return L("找不到可執行的背景工作程式。")
        case .notInstalled: return L("請先把 UTUVO Wallpaper 拖到「應用程式」資料夾，從那裡打開後再啟用背景服務。")
        case .invalidDataDirectory: return L("背景工作的資料夾位置無效。")
        case .cannotWritePlist: return L("無法儲存背景排程設定。")
        case .cannotRemovePlist: return L("無法移除背景排程設定。")
        case .commandUnavailable: return L("無法執行 macOS 背景排程管理工具。")
        case .commandFailed(let action, let status):
            return L("背景排程\(action)失敗（代碼 \(status)）。")
        }
    }
}

/// An advisory lock shared by the foreground App and background worker.
/// Keep the lease alive throughout the operation; do not unlink the lock file.
final class FileLease: @unchecked Sendable {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) { self.fileDescriptor = fileDescriptor }

    static func acquire(at url: URL) throws -> FileLease? {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw FileLeaseError.invalidURL }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw FileLeaseError.cannotCreateDirectory
        }
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw FileLeaseError.openFailed(errno) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return FileLease(fileDescriptor: descriptor)
        }
        let code = errno
        _ = Darwin.close(descriptor)
        if code == EWOULDBLOCK || code == EAGAIN { return nil }
        throw FileLeaseError.lockFailed(code)
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }
}

private enum FileLeaseError: LocalizedError {
    case invalidURL
    case cannotCreateDirectory
    case openFailed(Int32)
    case lockFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return L("生成鎖定檔位置無效。")
        case .cannotCreateDirectory: return L("無法建立生成鎖定檔的資料夾。")
        case .openFailed(let code): return L("無法開啟生成鎖定檔（代碼 \(code)）。")
        case .lockFailed(let code): return L("無法鎖定生成工作（代碼 \(code)）。")
        }
    }
}
