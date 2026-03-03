import Foundation

enum HistoryLogger {
    enum Mode: Equatable, CustomStringConvertible {
        enum DisabledReason: String, Equatable {
            case privacyMode = "privacy_mode"
            case userPreference = "user_preference"
            case legacyToggle = "legacy_toggle"
        }

        case enabled
        case disabled(reason: DisabledReason)

        var allowsPersistence: Bool {
            if case .enabled = self {
                return true
            }
            return false
        }

        var description: String {
            switch self {
            case .enabled:
                "enabled"
            case .disabled(let reason):
                "disabled:\(reason.rawValue)"
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 推荐使用 `mode` / `setPrivacyModeEnabled`，避免把“仅关闭历史记录”误解成完整隐私模式。
    static var mode: Mode = .enabled

    /// 兼容旧接口：false 时会标记为 `legacy_toggle`。
    static var enabled: Bool {
        get { mode.allowsPersistence }
        set {
            mode = newValue ? .enabled : .disabled(reason: .legacyToggle)
        }
    }

    static func setPrivacyModeEnabled(_ enabled: Bool) {
        mode = enabled ? .disabled(reason: .privacyMode) : .enabled
    }

    static func setHistoryLoggingEnabled(_ enabled: Bool) {
        mode = enabled ? .enabled : .disabled(reason: .userPreference)
    }

    static func log(_ text: String) {
        guard mode.allowsPersistence, !text.isEmpty else { return }

        DataPaths.ensureFileExists(at: DataPaths.historyFile)

        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(text)\n"

        guard let data = entry.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: DataPaths.historyFile) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }
}
