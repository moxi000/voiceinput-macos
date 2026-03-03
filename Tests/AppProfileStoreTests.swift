import Foundation
import Testing
@testable import VoiceInput

struct AppProfileStoreTests {
    @Test("默认档案包含最小字段")
    func defaultProfile() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppProfileStore(userDefaults: defaults)
        let profile = store.load()

        #expect(profile.inlineMode == false)
        #expect(profile.inlineInjectionDisabled == false)
        #expect(profile.llmPostProcessingEnabled == false)
        #expect(profile.historyLoggingEnabled == true)
        #expect(profile.privacyModeEnabled == false)
    }

    @Test("可保存并恢复应用档案")
    func saveAndLoadProfile() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppProfileStore(userDefaults: defaults)
        let expected = AppProfile(
            inlineMode: true,
            inlineInjectionDisabled: true,
            llmPostProcessingEnabled: true,
            historyLoggingEnabled: false,
            privacyModeEnabled: true
        )

        store.save(expected)
        let loaded = store.load()
        #expect(loaded == expected)
    }

    @Test("RuntimeTuning 支持集中配置并可重置")
    func runtimeTuningCanReset() {
        RuntimeTuning.llmProcessTimeoutSeconds = 1
        RuntimeTuning.llmConnectionTestTimeoutSeconds = 2
        RuntimeTuning.watchdogTimeoutSeconds = 3

        RuntimeTuning.resetToDefaults()

        #expect(RuntimeTuning.llmProcessTimeoutSeconds == 15)
        #expect(RuntimeTuning.llmConnectionTestTimeoutSeconds == 10)
        #expect(RuntimeTuning.watchdogTimeoutSeconds == 8)
    }

    @Test("HistoryLogger 提供语义化模式接口")
    func historyLoggerModeSemantics() {
        HistoryLogger.mode = .enabled
        #expect(HistoryLogger.enabled)

        HistoryLogger.setPrivacyModeEnabled(true)
        #expect(HistoryLogger.enabled == false)
        #expect(HistoryLogger.mode.description.contains("privacy") == true)

        HistoryLogger.setHistoryLoggingEnabled(true)
        #expect(HistoryLogger.enabled)

        HistoryLogger.enabled = false
        #expect(HistoryLogger.mode.description.contains("legacy") == true)

        HistoryLogger.mode = .enabled
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppProfileStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
