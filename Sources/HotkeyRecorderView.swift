import Cocoa

/// A dedicated panel for recording a hotkey combination.
/// Uses global event monitors to capture keys even if focus is lost.
/// Accumulates held modifiers and waits for a non-modifier key to complete the combo,
/// or accepts a single modifier press for modifier-only (double-tap) hotkeys.
class HotkeyRecorderView: NSTextField {
    /// Called when a new key combo is captured. (keyCode, modifiers)
    var onHotkeyRecorded: ((Int64, CGEventFlags) -> Void)?

    private var isRecording = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var currentModifiers: NSEvent.ModifierFlags = []
    private var modifierTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        stopRecording()
    }

    private func setup() {
        isEditable = false
        isSelectable = false
        alignment = .center
        font = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        isBezeled = true
        bezelStyle = .roundedBezel
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
        currentModifiers = []
        stringValue = "请按下快捷键组合..."
        textColor = .systemOrange

        // Global monitor captures events even if another app steals focus
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { [weak self] event in
            self?.handleRecordEvent(event)
        }

        // Local monitor captures events when this app is in focus
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { [weak self] event in
            self?.handleRecordEvent(event)
            return nil  // consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        textColor = .labelColor
        currentModifiers = []
        modifierTimer?.invalidate()
        modifierTimer = nil

        if let g = globalMonitor {
            NSEvent.removeMonitor(g)
            globalMonitor = nil
        }
        if let l = localMonitor {
            NSEvent.removeMonitor(l)
            localMonitor = nil
        }
    }

    private func handleRecordEvent(_ event: NSEvent) {
        // Mouse button
        if event.type == .otherMouseDown && event.buttonNumber == 2 {
            modifierTimer?.invalidate()
            modifierTimer = nil
            // Use keyCode=-2 as convention for middle mouse button
            onHotkeyRecorded?(-2, CGEventFlags())
            stringValue = "鼠标中键"
            stopRecording()
            return
        }

        if event.type == .keyDown {
            // Escape cancels recording
            if event.keyCode == 53 {
                stopRecording()
                stringValue = placeholderString ?? ""
                return
            }

            // Non-modifier key pressed: capture the combo (current modifiers + this key)
            modifierTimer?.invalidate()
            modifierTimer = nil

            let keyCode = Int64(event.keyCode)
            let cgFlags = convertModifiers(currentModifiers.union(event.modifierFlags))
            onHotkeyRecorded?(keyCode, cgFlags)
            stringValue = HotkeyConfig(keyCode: keyCode, modifiers: cgFlags).displayString
            stopRecording()

        } else if event.type == .flagsChanged {
            // Track which modifiers are currently held
            let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])

            if !mods.isEmpty {
                // Modifier pressed — accumulate and show live preview
                currentModifiers = mods
                stringValue = modifierDisplayString(mods) + "..."

                // Start/reset a timer: if no key is pressed within 1s,
                // accept as modifier-only hotkey (double-tap trigger)
                modifierTimer?.invalidate()
                let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    guard let self = self, self.isRecording else { return }
                    let cgFlags = self.convertModifiers(self.currentModifiers)
                    self.onHotkeyRecorded?(-1, cgFlags)
                    let config = HotkeyConfig(keyCode: -1, modifiers: cgFlags)
                    self.stringValue = config.displayString
                    self.stopRecording()
                }
                RunLoop.current.add(timer, forMode: .common)
                modifierTimer = timer
            }
            // When all modifiers are released without pressing a key,
            // keep waiting (don't reset) — user may re-press
        }
    }

    private func modifierDisplayString(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.joined()
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
