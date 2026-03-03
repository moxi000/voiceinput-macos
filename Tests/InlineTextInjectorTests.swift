import Testing
import Foundation
@testable import VoiceInput

struct InlineTextInjectorTests {
    @Test("undoLastInjection: can undo finalized text once")
    func undoLastInjectionRemovesFinalizedTextOnce() {
        let sink = MockTypingSink()
        let injector = InlineTextInjector(typingSink: sink)

        injector.finalize(with: "hello")

        let firstUndo = injector.undoLastInjection()
        let secondUndo = injector.undoLastInjection()

        #expect(firstUndo == true)
        #expect(secondUndo == false)
        #expect(sink.insertedStrings == ["hello"])
        #expect(sink.backspaceCounts == [5])
    }

    @Test("previewBeforeInjection: default false and can be enabled")
    func previewBeforeInjectionToggle() {
        let suiteName = "InlineTextInjectorTests.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(InlineTextInjector.isPreviewBeforeInjectionEnabled(userDefaults: defaults) == false)

        InlineTextInjector.setPreviewBeforeInjectionEnabled(true, userDefaults: defaults)

        #expect(InlineTextInjector.isPreviewBeforeInjectionEnabled(userDefaults: defaults) == true)
    }
}

private final class MockTypingSink: InlineTypingSink {
    private(set) var backspaceCounts: [Int] = []
    private(set) var insertedStrings: [String] = []

    func sendBackspaces(count: Int) {
        backspaceCounts.append(count)
    }

    func sendString(_ string: String) {
        insertedStrings.append(string)
    }
}
