import Cocoa
import Carbon.HIToolbox

/// Hotkey activation mode.
enum HotkeyMode: String {
    case holdToTalk  // press-and-hold to record, release to stop
    case handsFree   // press to start, press again to stop
}

/// A single hotkey configuration.
struct HotkeyConfig: Equatable {
    var keyCode: Int64           // virtual key code, -1 for modifier-only
    var modifiers: CGEventFlags  // required modifiers
    var mode: HotkeyMode

    /// Human-readable label, e.g. "⌥Z" or "Double ⌥"
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.maskControl)   { parts.append("⌃") }
        if modifiers.contains(.maskAlternate)  { parts.append("⌥") }
        if modifiers.contains(.maskShift)      { parts.append("⇧") }
        if modifiers.contains(.maskCommand)    { parts.append("⌘") }

        if keyCode >= 0 {
            parts.append(HotkeyConfig.keyName(for: keyCode))
        } else {
            // Modifier-only: show as "Double ⌥" etc.
            if parts.count == 1 {
                return "Double \(parts[0])"
            }
        }
        return parts.joined()
    }

    /// Default hotkey: Option+Z, hands-free
    static let `default` = HotkeyConfig(keyCode: 6, modifiers: .maskAlternate, mode: .handsFree)

    // MARK: - Persistence

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(keyCode, forKey: "hotkey_keycode")
        defaults.set(modifiers.rawValue, forKey: "hotkey_modifiers")
        defaults.set(mode.rawValue, forKey: "hotkey_mode")
    }

    static func load(from defaults: UserDefaults = .standard) -> HotkeyConfig {
        let code = defaults.object(forKey: "hotkey_keycode") as? Int64 ?? HotkeyConfig.default.keyCode
        let mods = defaults.object(forKey: "hotkey_modifiers") as? UInt64 ?? HotkeyConfig.default.modifiers.rawValue
        let modeStr = defaults.string(forKey: "hotkey_mode") ?? HotkeyConfig.default.mode.rawValue
        return HotkeyConfig(
            keyCode: code,
            modifiers: CGEventFlags(rawValue: mods),
            mode: HotkeyMode(rawValue: modeStr) ?? .handsFree
        )
    }

    // MARK: - Key name lookup

    static func keyName(for keyCode: Int64) -> String {
        let names: [Int64: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            48: "⇥", 49: "Space", 50: "`",
            51: "⌫", 53: "Esc",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14",
            109: "F10", 111: "F12", 113: "F15",
            115: "Home", 116: "PgUp", 117: "Del", 118: "F4",
            119: "End", 120: "F2", 121: "PgDn", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }
}

/// Manages the global hotkey via CGEvent tap.
/// Supports hold-to-talk, hands-free toggle, double-modifier shortcuts,
/// and middle mouse button toggle.
class HotkeyManager {
    var onRecordStart: (() -> Void)?
    var onRecordStop: (() -> Void)?

    private(set) var config: HotkeyConfig
    private var eventTap: CFMachPort?
    private var isHolding = false  // for hold-to-talk: is key currently held down?

    // Double-modifier detection
    private var lastModifierTapTime: Date?
    private let doubleTapInterval: TimeInterval = 0.35

    // Track modifier state for modifier-only hotkeys
    private var currentModifiers: CGEventFlags = []

    init(config: HotkeyConfig = .load()) {
        self.config = config
    }

    func updateConfig(_ newConfig: HotkeyConfig) {
        config = newConfig
        config.save()
        isHolding = false
        lastModifierTapTime = nil
        print("[HotkeyManager] Updated hotkey: \(config.displayString) mode=\(config.mode.rawValue)")
    }

    // MARK: - Install / Uninstall

    func install() -> Bool {
        // Check accessibility
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            print("[HotkeyManager] Accessibility permission required.")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "需要辅助功能权限"
                alert.informativeText = "VoiceInput 需要辅助功能权限来注册全局快捷键。\n请在 系统设置 → 隐私与安全性 → 辅助功能 中授予权限。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HotkeyManager.eventTapCallback,
            userInfo: refcon
        ) else {
            print("[HotkeyManager] Failed to create event tap.")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "快捷键注册失败"
                alert.informativeText = "无法创建全局快捷键。\n请确保已在 系统设置 → 隐私与安全性 → 辅助功能 中授予权限，然后重启应用。"
                alert.alertStyle = .critical
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[HotkeyManager] Installed, hotkey: \(config.displayString) mode=\(config.mode.rawValue)")
        return true
    }

    func uninstall() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    // MARK: - Event Tap Callback

    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
        return manager.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Middle mouse button — always hands-free toggle
        if type == .otherMouseDown && event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.isHolding {
                    self.isHolding = false
                    self.onRecordStop?()
                } else {
                    self.onRecordStart?()
                }
            }
            return nil
        }

        // Modifier-only hotkey (keyCode == -1): detect double-tap of modifier
        if config.keyCode < 0 {
            if type == .flagsChanged {
                return handleModifierOnlyHotkey(event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        // Regular key hotkey
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Check if the pressed key matches our hotkey
        guard keyCode == config.keyCode, matchesModifiers(flags) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            return handleKeyDown(event: event)
        case .keyUp:
            return handleKeyUp(event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Key Handling

    private func handleKeyDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Ignore key repeats (auto-repeat while holding)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat { return nil }

        switch config.mode {
        case .handsFree:
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.isHolding {
                    self.isHolding = false
                    self.onRecordStop?()
                } else {
                    self.isHolding = true
                    self.onRecordStart?()
                }
            }
        case .holdToTalk:
            if !isHolding {
                isHolding = true
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordStart?()
                }
            }
        }
        return nil  // consume the event
    }

    private func handleKeyUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        switch config.mode {
        case .handsFree:
            return nil  // consume but don't act
        case .holdToTalk:
            if isHolding {
                isHolding = false
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordStop?()
                }
            }
            return nil
        }
    }

    // MARK: - Modifier-Only Hotkey (Double-Tap)

    private func handleModifierOnlyHotkey(event: CGEvent) -> Unmanaged<CGEvent>? {
        let newFlags = event.flags
        let targetMod = config.modifiers

        // Isolate just the modifier bits we care about
        let relevantNew = newFlags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        let targetRelevant = targetMod.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])

        // Detect modifier key press (transition from not-pressed to pressed)
        let wasPressed = currentModifiers.contains(targetRelevant)
        let isPressed = relevantNew.contains(targetRelevant)
        currentModifiers = relevantNew

        if isPressed && !wasPressed {
            // Modifier just pressed — check for double-tap
            let now = Date()
            if let lastTap = lastModifierTapTime, now.timeIntervalSince(lastTap) < doubleTapInterval {
                // Double-tap detected!
                lastModifierTapTime = nil

                switch config.mode {
                case .handsFree:
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        if self.isHolding {
                            self.isHolding = false
                            self.onRecordStop?()
                        } else {
                            self.isHolding = true
                            self.onRecordStart?()
                        }
                    }
                case .holdToTalk:
                    if !isHolding {
                        isHolding = true
                        DispatchQueue.main.async { [weak self] in
                            self?.onRecordStart?()
                        }
                    }
                }
            } else {
                lastModifierTapTime = now
            }
        } else if !isPressed && wasPressed {
            // Modifier released
            if config.mode == .holdToTalk && isHolding {
                isHolding = false
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordStop?()
                }
            }
        }

        // Don't consume modifier events — other apps need them
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Helpers

    private func matchesModifiers(_ flags: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let required = config.modifiers.intersection(relevant)
        let actual = flags.intersection(relevant)
        return actual == required
    }

    /// Reset hold state (called externally when recording stops for other reasons, e.g. ASR error)
    func resetHoldState() {
        isHolding = false
    }
}
