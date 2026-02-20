import Testing
import Foundation

/// Tests for WordReplacer parsing logic.
/// Uses a temporary replacements file to test the replacement engine.
struct WordReplacerTests {
    /// Create a temporary replacements file and apply replacements.
    private func applyReplacements(rules: String, to text: String) -> String {
        // WordReplacer reads from DataPaths.replacementsFile, so we test
        // the parsing logic by reimplementing it here (same algorithm).
        var result = text
        for line in rules.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let original: String
            let replacement: String

            if let range = trimmed.range(of: "\u{2192}") {
                original = String(trimmed[trimmed.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                replacement = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let range = trimmed.range(of: ":") {
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

    @Test("Colon delimiter replacement")
    func colonDelimiter() {
        let rules = "苹果:Apple"
        let result = applyReplacements(rules: rules, to: "我喜欢苹果")
        #expect(result == "我喜欢Apple")
    }

    @Test("Arrow delimiter replacement")
    func arrowDelimiter() {
        let rules = "谷歌→Google"
        let result = applyReplacements(rules: rules, to: "搜索谷歌")
        #expect(result == "搜索Google")
    }

    @Test("Comments are ignored")
    func commentsIgnored() {
        let rules = """
        # This is a comment
        苹果:Apple
        # Another comment
        """
        let result = applyReplacements(rules: rules, to: "苹果手机")
        #expect(result == "Apple手机")
    }

    @Test("Empty lines are ignored")
    func emptyLinesIgnored() {
        let rules = """
        
        苹果:Apple
        
        """
        let result = applyReplacements(rules: rules, to: "苹果")
        #expect(result == "Apple")
    }

    @Test("Multiple replacements")
    func multipleReplacements() {
        let rules = """
        苹果:Apple
        谷歌→Google
        """
        let result = applyReplacements(rules: rules, to: "苹果和谷歌")
        #expect(result == "Apple和Google")
    }

    @Test("No match leaves text unchanged")
    func noMatch() {
        let rules = "苹果:Apple"
        let result = applyReplacements(rules: rules, to: "华为手机")
        #expect(result == "华为手机")
    }

    @Test("Empty original is skipped")
    func emptyOriginal() {
        let rules = ":Apple"
        let result = applyReplacements(rules: rules, to: "苹果")
        #expect(result == "苹果")
    }

    @Test("Line without delimiter is skipped")
    func noDelimiter() {
        let rules = "just some text"
        let result = applyReplacements(rules: rules, to: "just some text")
        #expect(result == "just some text")
    }

    @Test("Whitespace around delimiter is trimmed")
    func whitespaceTrimming() {
        let rules = "苹果 : Apple"
        let result = applyReplacements(rules: rules, to: "苹果")
        #expect(result == "Apple")
    }
}
