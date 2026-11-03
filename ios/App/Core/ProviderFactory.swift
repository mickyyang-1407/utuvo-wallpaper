import Foundation

/// 前景與背景共用的 provider 工廠：Debug 且帶 `-UTUVOFakeProvider YES` 時用假 provider（不連網），
/// 否則用使用者自己的 key（鑰匙圈 → OPENAI_API_KEY）。
enum ProviderFactory {
    static func usesFakeProvider(_ defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: "UTUVOFakeProvider")
        #else
        return false
        #endif
    }

    static func make(store: KeychainCredentialStore = KeychainCredentialStore(),
                     defaults: UserDefaults = .standard,
                     environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ImageProvider {
        #if DEBUG
        if usesFakeProvider(defaults) { return LoggingImageProvider(base: FakeImageProvider(), paths: .shared) }
        #endif
        guard let credential = CredentialResolver.resolve(store: store, environment: environment) else {
            throw GenerationError.missingCredential
        }
        return LoggingImageProvider(base: OpenAIImageProvider(apiKey: credential.key), paths: .shared)
    }
}

#if DEBUG
/// Debug 專用：`-UTUVOLiveOne YES` 時用「真的」OpenAI provider 只跑 1 張（第一個範本），
/// 進度檔用 `live-check-YYYY-MM-DD`，不占今天的每日批次。Release 完全不編入。
enum LiveOneCheck {
    static let argument = "UTUVOLiveOne"
    static func isRequested(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: argument) }
    static func day(_ date: Date = Date()) -> String { "live-check-" + AppPaths.dayString(date) }
}
#endif
