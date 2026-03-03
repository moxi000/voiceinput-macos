import Testing
import Cocoa
@testable import VoiceInput

struct TextInjectorTests {
    @Test("restorePasteboardNow: changeCount changed should skip restore")
    func restoreSkippedWhenChangeCountChanged() {
        let pasteboard = FakePasteboard()
        let snapshot: PasteboardSnapshot = [[(.string, Data("old".utf8))]]

        pasteboard.changeCount = 5
        let restored = TextInjector.restorePasteboardNow(snapshot, expectedChangeCount: 4, pasteboard: pasteboard)

        #expect(restored == false)
        #expect(pasteboard.clearCount == 0)
        #expect(pasteboard.writeCount == 0)
    }

    @Test("restorePasteboardNow: empty snapshot should still clear contents")
    func restoreEmptySnapshotClears() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [[(.string, Data("existing".utf8))]]
        pasteboard.changeCount = 8

        let restored = TextInjector.restorePasteboardNow([], expectedChangeCount: 8, pasteboard: pasteboard)

        #expect(restored == true)
        #expect(pasteboard.clearCount == 1)
        #expect(pasteboard.writeCount == 0)
        #expect(pasteboard.items.isEmpty)
    }
}

private final class FakePasteboard: TextInjectorPasteboard {
    var changeCount: Int = 0
    var items: PasteboardSnapshot = []

    private(set) var clearCount = 0
    private(set) var writeCount = 0

    func clearContents() {
        clearCount += 1
        changeCount += 1
        items = []
    }

    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) {
        changeCount += 1
        items = [[(type, Data(string.utf8))]]
    }

    func snapshotItems() -> PasteboardSnapshot {
        items
    }

    func writeSnapshotItems(_ snapshot: PasteboardSnapshot) {
        writeCount += 1
        changeCount += 1
        items = snapshot
    }
}
