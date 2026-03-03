import Foundation

enum RuntimeTuning {
    static let defaultLLMConnectionTestTimeoutSeconds: TimeInterval = 10
    static let defaultLLMProcessTimeoutSeconds: TimeInterval = 15
    static let defaultWatchdogTimeoutSeconds: TimeInterval = 8

    static var llmConnectionTestTimeoutSeconds: TimeInterval = defaultLLMConnectionTestTimeoutSeconds
    static var llmProcessTimeoutSeconds: TimeInterval = defaultLLMProcessTimeoutSeconds
    static var watchdogTimeoutSeconds: TimeInterval = defaultWatchdogTimeoutSeconds

    static func resetToDefaults() {
        llmConnectionTestTimeoutSeconds = defaultLLMConnectionTestTimeoutSeconds
        llmProcessTimeoutSeconds = defaultLLMProcessTimeoutSeconds
        watchdogTimeoutSeconds = defaultWatchdogTimeoutSeconds
    }
}
