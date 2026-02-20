import Foundation

enum WordReplacer {
    static func applyReplacements(to text: String) -> String {
        let url = DataPaths.replacementsFile
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return text
        }
        return applyReplacements(rules: content, to: text)
    }

    /// Apply replacement rules given as a multi-line string.
    /// Exposed as internal for testability.
    static func applyReplacements(rules: String, to text: String) -> String {
        var result = text
        for line in rules.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let original: String
            let replacement: String

            if let range = trimmed.range(of: "\u{2192}") {
                // Split on first →
                original = String(trimmed[trimmed.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                replacement = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let range = trimmed.range(of: ":") {
                // Split on first :
                original = String(trimmed[trimmed.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                replacement = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                continue
            }

            guard !original.isEmpty else { continue }
            result = result.replacingOccurrences(of: original, with: replacement)
        }
        return result
    }
}
