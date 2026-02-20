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

    /// Human-readable label, e.g. "⌥Z" or "Double ⌥"
    var displayString: String {
        // Special case: middle mouse button
        if keyCode == -2 { return "鼠标中键" }

        var parts: [String] = []
        if modifiers.contains(.maskControl)   { parts.append("⌃") }
        if modifiers.contains(.maskAlternate)  { parts.append("⌥") }
        if modifiers.contains(.maskShift)      { parts.append("⇧") }
        if modifiers.contains(.maskCommand)    { parts.append("⌘") }

        if keyCode >= 0 {
            parts.append(HotkeyConfig.keyName(for: keyCode))
        } else {
            if parts.count == 1 {
                return "双击\(parts[0])"
            }
        }
        return parts.joined()
    }

    /// Default hold-to-talk: Option+Z
    static let defaultHoldToTalk = HotkeyConfig(keyCode: 6, modifiers: .maskAlternate)
    /// Default hands-free: none (middle mouse only)
    static let defaultHandsFree: HotkeyConfig? = nil

    // MARK: - Persistence

    func save(prefix: String, to defaults: UserDefaults = .standard) {
        defaults.set(keyCode, forKey: "\(prefix)_keycode")
        defaults.set(modifiers.rawValue, forKey: "\(prefix)_modifiers")
        defaults.set(true, forKey: "\(prefix)_enabled")
    }

    static func load(prefix: String, fallback: HotkeyConfig?, from defaults: UserDefaults = .standard) -> HotkeyConfig? {
        guard defaults.bool(forKey: "\(prefix)_enabled") || defaults.object(forKey: "\(prefix)_enabled") == nil else {
            return fallback
        }
        guard let _ = defaults.object(forKey: "\(prefix)_keycode") else {
            return fallback
        }
        let code = defaults.object(forKey: "\(prefix)_keycode") as? Int64 ?? fallback?.keyCode ?? 6
        let mods = defaults.object(forKey: "\(prefix)_modifiers") as? UInt64 ?? fallback?.modifiers.rawValue ?? 0
        return HotkeyConfig(keyCode: code, modifiers: CGEventFlags(rawValue: mods))
    }

    static func clear(prefix: String, from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "\(prefix)_keycode")
        defaults.removeObject(forKey: "\(prefix)_modifiers")
        defaults.set(false, forKey: "\(prefix)_enabled")
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

// MARK: - HotkeyManager

/// Manages two global hotkeys via CGEvent tap:
///   - holdToTalk: press-and-hold to record, release any key to stop
///   - handsFree:  press to start, press again to stop
/// Middle mouse button is always hands-free toggle.
class HotkeyManager {
    var onRecordStart: ((_ mode: HotkeyMode) -> Void)?
    var onRecordStop: (() -> Void)?

    private(set) var holdToTalkConfig: HotkeyConfig?
    private(set) var handsFreeConfig: HotkeyConfig?

    private var eventTap: CFMachPort?
    private var isHolding = false
    private var activeMode: HotkeyMode?
    var suspended = false  // suppress all hotkey handling (e.g. during config dialog)  // which mode triggered current recording

    // Double-modifier detection (for modifier-only hotkeys)
    private var lastModTapTime: [String: Date] = [:]  // "hold"/"free" -> last tap time
    private let doubleTapInterval: TimeInterval = 0.35
    private var currentModifiers: CGEventFlags = []

    init() {
        holdToTalkConfig = HotkeyConfig.load(prefix: "hotkey_hold", fallback: .defaultHoldToTalk)
        handsFreeConfig = HotkeyConfig.load(prefix: "hotkey_free", fallback: nil)
    }

    func setHoldToTalk(_ config: HotkeyConfig?) {
        holdToTalkConfig = config
        if let c = config { c.save(prefix: "hotkey_hold") }
        else { HotkeyConfig.clear(prefix: "hotkey_hold") }
        resetState()
        print("[HotkeyManager] Hold-to-talk: \(config?.displayString ?? "disabled")")
    }

    func setHandsFree(_ config: HotkeyConfig?) {
        handsFreeConfig = config
        if let c = config { c.save(prefix: "hotkey_free") }
        else { HotkeyConfig.clear(prefix: "hotkey_free") }
        resetState()
        print("[HotkeyManager] Hands-free: \(config?.displayString ?? "middle mouse only")")
    }

    // MARK: - Install / Uninstall

    func install() -> Bool {
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
        print("[HotkeyManager] Installed. Hold: \(holdToTalkConfig?.displayString ?? "disabled"), Free: \(handsFreeConfig?.displayString ?? "mouse only")")
        return true
    }

    func uninstall() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    func resetState() {
        isHolding = false
        activeMode = nil
    }

    // MARK: - Event Tap

    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = mgr.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("[HotkeyManager] Re-enabled event tap")
            }
            return Unmanaged.passUnretained(event)
        }

        return mgr.handleEvent(type: type, event: event)
    }

    // MARK: - Event Dispatch

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Skip all handling while suspended (e.g. hotkey config dialog open)
        if suspended { return Unmanaged.passUnretained(event) }
        // Middle mouse button — always hands-free toggle
        if type == .otherMouseDown && event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.isHolding {
                    self.isHolding = false
                    self.activeMode = nil
                    self.onRecordStop?()
                } else {
                    self.isHolding = true
                    self.activeMode = .handsFree
                    self.onRecordStart?(.handsFree)
                }
            }
            return nil
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // --- If currently holding (recording), check for release ---
        if isHolding && activeMode == .holdToTalk {
            // keyUp of the hold key — stop (ignore modifiers, user may release in any order)
            if type == .keyUp, let htc = holdToTalkConfig, htc.keyCode >= 0, keyCode == htc.keyCode {
                isHolding = false
                activeMode = nil
                DispatchQueue.main.async { [weak self] in self?.onRecordStop?() }
                return nil
            }
            // Modifier released during hold — stop if it was in hold config
            if type == .flagsChanged, let htc = holdToTalkConfig {
                if htc.keyCode < 0 || !matchesMods(flags, htc.modifiers) {
                    isHolding = false
                    activeMode = nil
                    DispatchQueue.main.async { [weak self] in self?.onRecordStop?() }
                }
                return Unmanaged.passUnretained(event)
            }
        }

        // --- Check for hotkey activation ---
        if type == .flagsChanged {
            currentModifiers = flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            // Check modifier-only hotkeys (double-tap)
            if let result = checkModifierOnly(holdToTalkConfig, tag: "hold", mode: .holdToTalk) { return result }
            if let result = checkModifierOnly(handsFreeConfig, tag: "free", mode: .handsFree) { return result }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat { return isHolding ? nil : Unmanaged.passUnretained(event) }

            // Check hold-to-talk
            if let htc = holdToTalkConfig, htc.keyCode >= 0,
               keyCode == htc.keyCode, matchesMods(flags, htc.modifiers) {
                if !isHolding {
                    isHolding = true
                    activeMode = .holdToTalk
                    DispatchQueue.main.async { [weak self] in self?.onRecordStart?(.holdToTalk) }
                }
                return nil
            }

            // Check hands-free
            if let hfc = handsFreeConfig, hfc.keyCode >= 0,
               keyCode == hfc.keyCode, matchesMods(flags, hfc.modifiers) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.isHolding {
                        self.isHolding = false
                        self.activeMode = nil
                        self.onRecordStop?()
                    } else {
                        self.isHolding = true
                        self.activeMode = .handsFree
                        self.onRecordStart?(.handsFree)
                    }
                }
                return nil
            }
        }

        // keyUp for hands-free: consume but don't act
        if type == .keyUp {
            if let hfc = handsFreeConfig, hfc.keyCode >= 0, keyCode == hfc.keyCode {
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Modifier-only double-tap

    private func checkModifierOnly(_ config: HotkeyConfig?, tag: String, mode: HotkeyMode) -> Unmanaged<CGEvent>? {
        guard let cfg = config, cfg.keyCode == -1 else { return nil }

        let targetMods = cfg.modifiers.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        let isPressed = currentModifiers.contains(targetMods)

        if isPressed {
            let now = Date()
            if let last = lastModTapTime[tag], now.timeIntervalSince(last) < doubleTapInterval {
                lastModTapTime[tag] = nil
                // Double-tap detected
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if mode == .holdToTalk {
                        if !self.isHolding {
                            self.isHolding = true
                            self.activeMode = .holdToTalk
                            self.onRecordStart?(.holdToTalk)
                        }
                    } else {
                        if self.isHolding {
                            self.isHolding = false
                            self.activeMode = nil
                            self.onRecordStop?()
                        } else {
                            self.isHolding = true
                            self.activeMode = .handsFree
                            self.onRecordStart?(.handsFree)
                        }
                    }
                }
            } else {
                lastModTapTime[tag] = now
            }
        }
        return nil  // don't consume modifier events
    }

    // MARK: - Helpers

    private func matchesMods(_ flags: CGEventFlags, _ required: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        return flags.intersection(relevant) == required.intersection(relevant)
    }
}
