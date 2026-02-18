import Cocoa

/// Injects text at the current cursor position by writing to the pasteboard
/// and simulating Cmd+V.
class TextInjector {
    /// Paste text into a specific app (re-activate it first), or into the current frontmost app.
    static func paste(_ text: String, targetApp: NSRunningApplication? = nil) {
        // Save current pasteboard content
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Write our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Re-activate the target app if provided
        if let app = targetApp {
            app.activate(options: [.activateIgnoringOtherApps])
            // Small delay to let the app come to front
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                simulatePaste()
                restorePasteboard(previousContents)
            }
        } else {
            simulatePaste()
            restorePasteboard(previousContents)
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

    private static func restorePasteboard(_ previous: String?) {
        if let prev = previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(prev, forType: .string)
            }
        }
    }
}
