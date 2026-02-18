import Cocoa

/// Types text directly into the active input field using CGEvent keyboard simulation.
/// Uses common-prefix diffing to minimize keystrokes when ASR updates partial results.
class InlineTextInjector {
    /// The full text that has been typed into the target field so far.
    private var lastTypedText: String = ""

    private let eventSource = CGEventSource(stateID: .privateState)

    /// Reset state. Call when starting a new recording session.
    func reset() {
        lastTypedText = ""
    }

    /// Update the typed text to match `newFullText`.
    /// Diffs against lastTypedText: deletes from divergence point, then types new suffix.
    func update(to newFullText: String) {
        let oldChars = Array(lastTypedText)
        let newChars = Array(newFullText)
        let commonLen = commonPrefixLength(oldChars, newChars)

        let deleteCount = oldChars.count - commonLen
        let insertSuffix = String(newChars[commonLen...])

        if deleteCount == 0 && insertSuffix.isEmpty { return }

        if deleteCount > 0 {
            sendBackspaces(count: deleteCount)
        }
        if !insertSuffix.isEmpty {
            sendString(insertSuffix)
        }

        lastTypedText = newFullText
    }

    /// Apply final corrections (e.g., after WordReplacer), then reset state.
    func finalize(with finalText: String) {
        update(to: finalText)
        lastTypedText = ""
    }

    /// Delete ALL text that was typed (for error recovery / cancellation).
    func deleteAll() {
        if !lastTypedText.isEmpty {
            sendBackspaces(count: lastTypedText.count)
        }
        lastTypedText = ""
    }

    // MARK: - CGEvent Simulation

    private func sendBackspaces(count: Int) {
        for i in 0..<count {
            let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x33, keyDown: true)
            down?.post(tap: .cgSessionEventTap)
            let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x33, keyDown: false)
            up?.post(tap: .cgSessionEventTap)
            // Brief pause every 20 backspaces to let the target app process
            if i > 0 && i % 20 == 0 {
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
    }

    private func sendString(_ string: String) {
        let utf16 = Array(string.utf16)
        let chunkSize = 20  // macOS CGEvent limit per keyboardSetUnicodeString call

        var offset = 0
        while offset < utf16.count {
            var end = min(offset + chunkSize, utf16.count)
            // Don't split a surrogate pair at the chunk boundary
            if end < utf16.count && UTF16.isLeadSurrogate(utf16[end - 1]) {
                end -= 1
            }
            var chunk = Array(utf16[offset..<end])

            let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down?.post(tap: .cgSessionEventTap)

            let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
            up?.post(tap: .cgSessionEventTap)

            offset = end
            if offset < utf16.count {
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
    }

    // MARK: - Diffing

    private func commonPrefixLength(_ a: [Character], _ b: [Character]) -> Int {
        let minLen = min(a.count, b.count)
        for i in 0..<minLen {
            if a[i] != b[i] { return i }
        }
        return minLen
    }
}
