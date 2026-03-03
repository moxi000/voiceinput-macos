import Foundation

struct AppProfile: Equatable {
    var inlineMode: Bool
    var inlineInjectionDisabled: Bool
    var llmPostProcessingEnabled: Bool
    var historyLoggingEnabled: Bool
    var privacyModeEnabled: Bool

    static let `default` = AppProfile(
        inlineMode: false,
        inlineInjectionDisabled: false,
        llmPostProcessingEnabled: false,
        historyLoggingEnabled: true,
        privacyModeEnabled: false
    )
}

final class AppProfileStore {
    private enum Keys {
        static let inlineMode = "inline_mode"
        static let inlineInjectionDisabled = "inline_injection_disabled"
        static let llmPostEnabled = "llm_post_enabled"
        static let historyLoggingEnabled = "history_logging_enabled"
        static let privacyMode = "privacy_mode"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> AppProfile {
        AppProfile(
            inlineMode: bool(forKey: Keys.inlineMode, default: AppProfile.default.inlineMode),
            inlineInjectionDisabled: bool(forKey: Keys.inlineInjectionDisabled, default: AppProfile.default.inlineInjectionDisabled),
            llmPostProcessingEnabled: bool(forKey: Keys.llmPostEnabled, default: AppProfile.default.llmPostProcessingEnabled),
            historyLoggingEnabled: bool(forKey: Keys.historyLoggingEnabled, default: AppProfile.default.historyLoggingEnabled),
            privacyModeEnabled: bool(forKey: Keys.privacyMode, default: AppProfile.default.privacyModeEnabled)
        )
    }

    func save(_ profile: AppProfile) {
        userDefaults.set(profile.inlineMode, forKey: Keys.inlineMode)
        userDefaults.set(profile.inlineInjectionDisabled, forKey: Keys.inlineInjectionDisabled)
        userDefaults.set(profile.llmPostProcessingEnabled, forKey: Keys.llmPostEnabled)
        userDefaults.set(profile.historyLoggingEnabled, forKey: Keys.historyLoggingEnabled)
        userDefaults.set(profile.privacyModeEnabled, forKey: Keys.privacyMode)
    }

    private func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard userDefaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return userDefaults.bool(forKey: key)
    }
}
