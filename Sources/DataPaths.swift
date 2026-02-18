import Foundation

enum DataPaths {
    static let supportDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VoiceInput")
    }()

    static let replacementsFile: URL = supportDirectory.appendingPathComponent("replacements.txt")
    static let hotwordsFile: URL = supportDirectory.appendingPathComponent("hotwords.txt")
    static let historyFile: URL = supportDirectory.appendingPathComponent("history.txt")

    static func ensureDataDirectory() {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            print("[DataPaths] Failed to create support directory: \(error)")
        }
    }

    static func ensureFileExists(at url: URL, defaultContent: String = "") {
        ensureDataDirectory()
        if !FileManager.default.fileExists(atPath: url.path) {
            if !FileManager.default.createFile(atPath: url.path, contents: defaultContent.data(using: .utf8)) {
                print("[DataPaths] Failed to create file: \(url.path)")
            }
        }
    }
}
