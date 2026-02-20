import Testing
@testable import VoiceInput

/// Tests for WordReplacer's parsing and replacement logic.
/// Calls the production WordReplacer.applyReplacements(rules:to:) directly.
struct WordReplacerTests {
    @Test("Colon delimiter replacement")
    func colonDelimiter() {
        let result = WordReplacer.applyReplacements(rules: "苹果:Apple", to: "我喜欢苹果")
        #expect(result == "我喜欢Apple")
    }

    @Test("Arrow delimiter replacement")
    func arrowDelimiter() {
        let result = WordReplacer.applyReplacements(rules: "谷歌→Google", to: "搜索谷歌")
        #expect(result == "搜索Google")
    }

    @Test("Comments are ignored")
    func commentsIgnored() {
        let rules = """
        # This is a comment
        苹果:Apple
        # Another comment
        """
        let result = WordReplacer.applyReplacements(rules: rules, to: "苹果手机")
        #expect(result == "Apple手机")
    }

    @Test("Empty lines are ignored")
    func emptyLinesIgnored() {
        let rules = """
        
        苹果:Apple
        
        """
        let result = WordReplacer.applyReplacements(rules: rules, to: "苹果")
        #expect(result == "Apple")
    }

    @Test("Multiple replacements")
    func multipleReplacements() {
        let rules = """
        苹果:Apple
        谷歌→Google
        """
        let result = WordReplacer.applyReplacements(rules: rules, to: "苹果和谷歌")
        #expect(result == "Apple和Google")
    }

    @Test("No match leaves text unchanged")
    func noMatch() {
        let result = WordReplacer.applyReplacements(rules: "苹果:Apple", to: "华为手机")
        #expect(result == "华为手机")
    }

    @Test("Empty original is skipped")
    func emptyOriginal() {
        let result = WordReplacer.applyReplacements(rules: ":Apple", to: "苹果")
        #expect(result == "苹果")
    }

    @Test("Line without delimiter is skipped")
    func noDelimiter() {
        let result = WordReplacer.applyReplacements(rules: "just some text", to: "just some text")
        #expect(result == "just some text")
    }

    @Test("Whitespace around delimiter is trimmed")
    func whitespaceTrimming() {
        let result = WordReplacer.applyReplacements(rules: "苹果 : Apple", to: "苹果")
        #expect(result == "Apple")
    }
}
