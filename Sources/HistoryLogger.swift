import Foundation

enum HistoryLogger {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// When false, calls to `log()` are no-ops (privacy mode).
    static var enabled: Bool = true

    static func log(_ text: String) {
        guard enabled, !text.isEmpty else { return }

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
