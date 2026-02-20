import Cocoa

/// A text field that captures a key combination when focused.
/// Used in the hotkey settings dialog.
class HotkeyRecorderView: NSTextField {
    /// Called when a new key combo is captured. (keyCode, modifiers)
    var onHotkeyRecorded: ((Int64, CGEventFlags) -> Void)?

    private var isRecording = false
    private var localMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isEditable = false
        isSelectable = false
        alignment = .center
        font = NSFont.systemFont(ofSize: 14, weight: .medium)
        placeholderString = "点击此处录制快捷键"
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        stringValue = "请按下快捷键..."
        textColor = .systemOrange

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleRecordEvent(event)
            return nil  // consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        textColor = .labelColor
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleRecordEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // Escape cancels recording
            if event.keyCode == 53 {
                stopRecording()
                stringValue = placeholderString ?? ""
                return
            }

            let keyCode = Int64(event.keyCode)
            let modifiers = convertModifiers(event.modifierFlags)
            onHotkeyRecorded?(keyCode, modifiers)
            stringValue = HotkeyConfig(keyCode: keyCode, modifiers: modifiers, mode: .handsFree).displayString
            stopRecording()

        } else if event.type == .flagsChanged {
            // Modifier-only: detect a modifier press (for double-tap style)
            let mods = event.modifierFlags
            let cgFlags = convertModifiers(mods)

            // Only accept if exactly one modifier is pressed
            let modCount = [
                mods.contains(.control),
                mods.contains(.option),
                mods.contains(.shift),
                mods.contains(.command)
            ].filter { $0 }.count

            if modCount == 1 {
                // User pressed a single modifier — record as modifier-only hotkey
                onHotkeyRecorded?(-1, cgFlags)
                let config = HotkeyConfig(keyCode: -1, modifiers: cgFlags, mode: .handsFree)
                stringValue = config.displayString
                stopRecording()
            }
        }
    }

    private func convertModifiers(_ nsFlags: NSEvent.ModifierFlags) -> CGEventFlags {
        var cg = CGEventFlags()
        if nsFlags.contains(.control)  { cg.insert(.maskControl) }
        if nsFlags.contains(.option)   { cg.insert(.maskAlternate) }
        if nsFlags.contains(.shift)    { cg.insert(.maskShift) }
        if nsFlags.contains(.command)  { cg.insert(.maskCommand) }
        return cg
    }

    /// Display a config's key combo.
    func display(_ config: HotkeyConfig) {
        stringValue = config.displayString
    }
}
