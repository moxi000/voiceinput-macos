import Testing
@testable import VoiceInput

/// Tests for InlineTextInjector's diff algorithm.
/// Calls the production static methods directly.
struct InlineDiffTests {
    @Test("Empty to non-empty")
    func emptyToNonEmpty() {
        let (del, ins) = InlineTextInjector.computeDiff(old: "", new: "hello")
        #expect(del == 0)
        #expect(ins == "hello")
    }

    @Test("Non-empty to empty")
    func nonEmptyToEmpty() {
        let (del, ins) = InlineTextInjector.computeDiff(old: "hello", new: "")
        #expect(del == 5)
        #expect(ins == "")
    }

    @Test("Identical strings — the crash scenario from Issue #1")
    func identicalStrings() {
        let (del, ins) = InlineTextInjector.computeDiff(old: "hello", new: "hello")
        #expect(del == 0)
        #expect(ins == "")
    }

    @Test("Completely different strings")
    func completelyDifferent() {
        let (del, ins) = InlineTextInjector.computeDiff(old: "abc", new: "xyz")
        #expect(del == 3)
        #expect(ins == "xyz")
    }

    @Test("Common prefix with different suffix")
    func commonPrefixDiff() {
        let (del, ins) = InlineTextInjector.computeDiff(old: "hello world", new: "hello swift")
        #expect(del == 5)   // delete "world"
        #expect(ins == "swift")
    }

    @Test("Extending existing text")
    func extending() {
        let (del, ins) = InlineTextInjector.computeDiff(old: "hel", new: "hello")
        #expect(del == 0)
        #expect(ins == "lo")
    }

    @Test("Shortening existing text")
    func shortening() {
        let (del, ins) = InlineTextInjector.computeDiff(old: "hello", new: "hel")
        #expect(del == 2)
        #expect(ins == "")
    }

    @Test("Unicode characters")
    func unicodeDiff() {
        let (del, ins) = InlineTextInjector.computeDiff(old: "你好世界", new: "你好Swift")
        #expect(del == 2)     // delete "世界"
        #expect(ins == "Swift")
    }

    @Test("Empty to empty")
    func emptyToEmpty() {
        let (del, ins) = InlineTextInjector.computeDiff(old: "", new: "")
        #expect(del == 0)
        #expect(ins == "")
    }
}
