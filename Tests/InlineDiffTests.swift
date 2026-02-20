import Testing

/// Tests for the InlineTextInjector diff logic.
/// Exercises the common-prefix diffing algorithm that determines
/// how many backspaces to send and what suffix to type.
struct InlineDiffTests {
    /// Compute common prefix length between two character arrays.
    /// This mirrors the private method in InlineTextInjector.
    private func commonPrefixLength(_ a: [Character], _ b: [Character]) -> Int {
        let minLen = min(a.count, b.count)
        for i in 0..<minLen {
            if a[i] != b[i] { return i }
        }
        return minLen
    }

    /// Compute the diff result: (deleteCount, insertSuffix).
    private func computeDiff(old: String, new: String) -> (deleteCount: Int, insertSuffix: String) {
        let oldChars = Array(old)
        let newChars = Array(new)
        let commonLen = commonPrefixLength(oldChars, newChars)
        let deleteCount = oldChars.count - commonLen
        let insertSuffix = String(new.dropFirst(commonLen))
        return (deleteCount, insertSuffix)
    }

    @Test("Empty to non-empty")
    func emptyToNonEmpty() {
        let (del, ins) = computeDiff(old: "", new: "hello")
        #expect(del == 0)
        #expect(ins == "hello")
    }

    @Test("Non-empty to empty")
    func nonEmptyToEmpty() {
        let (del, ins) = computeDiff(old: "hello", new: "")
        #expect(del == 5)
        #expect(ins == "")
    }

    @Test("Identical strings — the crash scenario from Issue #1")
    func identicalStrings() {
        let (del, ins) = computeDiff(old: "hello", new: "hello")
        #expect(del == 0)
        #expect(ins == "")
    }

    @Test("Completely different strings")
    func completelyDifferent() {
        let (del, ins) = computeDiff(old: "abc", new: "xyz")
        #expect(del == 3)
        #expect(ins == "xyz")
    }

    @Test("Common prefix with different suffix")
    func commonPrefixDiff() {
        let (del, ins) = computeDiff(old: "hello world", new: "hello swift")
        #expect(del == 5)   // delete "world"
        #expect(ins == "swift")
    }

    @Test("Extending existing text")
    func extending() {
        let (del, ins) = computeDiff(old: "hel", new: "hello")
        #expect(del == 0)
        #expect(ins == "lo")
    }

    @Test("Shortening existing text")
    func shortening() {
        let (del, ins) = computeDiff(old: "hello", new: "hel")
        #expect(del == 2)
        #expect(ins == "")
    }

    @Test("Unicode characters")
    func unicodeDiff() {
        let (del, ins) = computeDiff(old: "你好世界", new: "你好Swift")
        #expect(del == 2)     // delete "世界"
        #expect(ins == "Swift")
    }

    @Test("Empty to empty")
    func emptyToEmpty() {
        let (del, ins) = computeDiff(old: "", new: "")
        #expect(del == 0)
        #expect(ins == "")
    }
}
