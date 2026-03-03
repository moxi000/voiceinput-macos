import Cocoa

typealias PasteboardSnapshot = [[(NSPasteboard.PasteboardType, Data)]]

protocol TextInjectorPasteboard {
    var changeCount: Int { get }
    func clearContents()
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType)
    func snapshotItems() -> PasteboardSnapshot
    func writeSnapshotItems(_ snapshot: PasteboardSnapshot)
}

private struct NSPasteboardAdapter: TextInjectorPasteboard {
    let pasteboard: NSPasteboard

    var changeCount: Int {
        pasteboard.changeCount
    }

    func clearContents() {
        pasteboard.clearContents()
    }

    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) {
        pasteboard.setString(string, forType: type)
    }

    func snapshotItems() -> PasteboardSnapshot {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    func writeSnapshotItems(_ snapshot: PasteboardSnapshot) {
        let nsItems = snapshot.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(nsItems)
    }
}

/// Injects text at the current cursor position by writing to the pasteboard
/// and simulating Cmd+V.
class TextInjector {
    /// Paste text into a specific app (re-activate it first), or into the current frontmost app.
    static func paste(_ text: String, targetApp: NSRunningApplication? = nil) {
        // Save ALL current pasteboard content (including images, RTF, etc.)
        let pasteboard = NSPasteboardAdapter(pasteboard: .general)
        let previousItems = savePasteboardItems(pasteboard)
        let writeChangeCount = writeText(text, to: pasteboard)

        // Re-activate the target app if provided
        if let app = targetApp {
            app.activate()
            // Small delay to let the app come to front
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                simulatePaste()
                restorePasteboard(previousItems, expectedChangeCount: writeChangeCount, pasteboard: pasteboard)
            }
        } else {
            simulatePaste()
            restorePasteboard(previousItems, expectedChangeCount: writeChangeCount, pasteboard: pasteboard)
        }

        print("[TextInjector] Pasted \(text.count) chars to \(targetApp?.localizedName ?? "frontmost")")
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    // MARK: - Full Pasteboard Save/Restore

    /// Save all pasteboard items with all their type/data pairs.
    static func savePasteboardItems(_ pasteboard: any TextInjectorPasteboard) -> PasteboardSnapshot {
        pasteboard.snapshotItems()
    }

    /// Write text to pasteboard and return the changeCount immediately after writing.
    @discardableResult
    static func writeText(_ text: String, to pasteboard: any TextInjectorPasteboard) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    /// Restore previously saved pasteboard items after a delay.
    static func restorePasteboard(
        _ items: PasteboardSnapshot,
        expectedChangeCount: Int,
        pasteboard: any TextInjectorPasteboard,
        delay: TimeInterval = 0.3,
        scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        scheduler(delay) {
            _ = restorePasteboardNow(items, expectedChangeCount: expectedChangeCount, pasteboard: pasteboard)
        }
    }

    /// Restore saved snapshot only when pasteboard was not changed by the user since our write.
    @discardableResult
    static func restorePasteboardNow(
        _ items: PasteboardSnapshot,
        expectedChangeCount: Int,
        pasteboard: any TextInjectorPasteboard
    ) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else {
            print("[TextInjector] Skip pasteboard restore: pasteboard changed externally")
            return false
        }

        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeSnapshotItems(items)
        }
        return true
    }
}
