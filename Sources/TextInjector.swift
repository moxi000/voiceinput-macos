import Cocoa

/// Injects text at the current cursor position by writing to the pasteboard
/// and simulating Cmd+V.
class TextInjector {
    /// Paste text into a specific app (re-activate it first), or into the current frontmost app.
    static func paste(_ text: String, targetApp: NSRunningApplication? = nil) {
        // Save ALL current pasteboard content (including images, RTF, etc.)
        let pasteboard = NSPasteboard.general
        let previousItems = savePasteboardItems(pasteboard)

        // Write our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Re-activate the target app if provided
        if let app = targetApp {
            app.activate()
            // Small delay to let the app come to front
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                simulatePaste()
                restorePasteboard(previousItems)
            }
        } else {
            simulatePaste()
            restorePasteboard(previousItems)
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
    private static func savePasteboardItems(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    /// Restore previously saved pasteboard items after a delay.
    private static func restorePasteboard(_ items: [[(NSPasteboard.PasteboardType, Data)]]) {
        guard !items.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let nsItems = items.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(nsItems)
        }
    }
}
