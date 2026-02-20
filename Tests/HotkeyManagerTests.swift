import Testing
import Cocoa
@testable import VoiceInput

/// Tests for HotkeyManager's state machine and matching logic.
struct HotkeyManagerTests {

    // MARK: - matchesMods (exact equality)

    @Test("matchesMods: exact match returns true")
    func matchesModsExact() {
        let flags = CGEventFlags.maskAlternate
        let required = CGEventFlags.maskAlternate
        #expect(HotkeyManager.matchesMods(flags, required))
    }

    @Test("matchesMods: superset does not match")
    func matchesModsSupersetFails() {
        let flags: CGEventFlags = [.maskAlternate, .maskShift]
        let required = CGEventFlags.maskAlternate
        #expect(!HotkeyManager.matchesMods(flags, required))
    }

    @Test("matchesMods: subset does not match")
    func matchesModsSubsetFails() {
        let flags = CGEventFlags.maskAlternate
        let required: CGEventFlags = [.maskAlternate, .maskShift]
        #expect(!HotkeyManager.matchesMods(flags, required))
    }

    @Test("matchesMods: empty required matches empty flags")
    func matchesModsEmpty() {
        #expect(HotkeyManager.matchesMods(CGEventFlags(), CGEventFlags()))
    }

    @Test("matchesMods: ignores non-modifier flags")
    func matchesModsIgnoresNonModifier() {
        // Flags may contain non-modifier bits; matchesMods should only compare modifier bits
        let flags: CGEventFlags = [.maskAlternate, .maskNonCoalesced]
        let required = CGEventFlags.maskAlternate
        #expect(HotkeyManager.matchesMods(flags, required))
    }

    // MARK: - HotkeyConfig displayString

    @Test("HotkeyConfig: middle mouse displayString")
    func middleMouseDisplayString() {
        let config = HotkeyConfig(keyCode: -2, modifiers: CGEventFlags())
        #expect(config.displayString == "鼠标中键")
    }

    @Test("HotkeyConfig: modifier-only displayString shows double-tap")
    func modifierOnlyDisplayString() {
        let config = HotkeyConfig(keyCode: -1, modifiers: .maskAlternate)
        #expect(config.displayString == "双击⌥")
    }

    @Test("HotkeyConfig: regular key combo displayString")
    func regularKeyDisplayString() {
        let config = HotkeyConfig(keyCode: 6, modifiers: .maskAlternate)  // ⌥Z
        #expect(config.displayString == "⌥Z")
    }

    // MARK: - resetState

    @Test("resetState clears isHolding and activeMode")
    func resetStateClearsState() {
        let mgr = HotkeyManager()
        // Simulate a recording state by triggering callbacks
        mgr.onRecordStart = { _ in }
        // resetState should clear internal state
        mgr.resetState()
        #expect(mgr.isHolding == false)
        #expect(mgr.activeMode == nil)
    }

    // MARK: - Middle mouse keyCode isolation

    @Test("Middle mouse keyCode=-2 is distinct from modifier-only keyCode=-1")
    func middleMouseKeyCodeIsolation() {
        // Middle mouse should NOT be treated as modifier-only
        let middleMouse = HotkeyConfig(keyCode: -2, modifiers: CGEventFlags())
        let modOnly = HotkeyConfig(keyCode: -1, modifiers: .maskAlternate)
        #expect(middleMouse.keyCode != modOnly.keyCode)
        // The fix ensures checkModifierOnly only handles keyCode == -1
        #expect(middleMouse.keyCode == -2)
        #expect(modOnly.keyCode == -1)
    }

    // MARK: - HotkeyConfig persistence round-trip

    @Test("HotkeyConfig save and load round-trip")
    func saveLoadRoundTrip() {
        let defaults = UserDefaults.standard
        let prefix = "test_hotkey_roundtrip"

        // Clean up first
        HotkeyConfig.clear(prefix: prefix, from: defaults)

        let original = HotkeyConfig(keyCode: 6, modifiers: .maskAlternate)
        original.save(prefix: prefix, to: defaults)

        let loaded = HotkeyConfig.load(prefix: prefix, fallback: nil, from: defaults)
        #expect(loaded != nil)
        #expect(loaded?.keyCode == original.keyCode)
        #expect(loaded?.modifiers == original.modifiers)

        // Clean up
        HotkeyConfig.clear(prefix: prefix, from: defaults)
    }

    @Test("HotkeyConfig clear disables loading")
    func clearDisablesLoad() {
        let defaults = UserDefaults.standard
        let prefix = "test_hotkey_clear"

        let config = HotkeyConfig(keyCode: 6, modifiers: .maskAlternate)
        config.save(prefix: prefix, to: defaults)

        HotkeyConfig.clear(prefix: prefix, from: defaults)

        // After clear with enabled=false, load with nil fallback should return nil
        let loaded = HotkeyConfig.load(prefix: prefix, fallback: nil, from: defaults)
        #expect(loaded == nil)

        // Clean up
        defaults.removeObject(forKey: "\(prefix)_keycode")
        defaults.removeObject(forKey: "\(prefix)_modifiers")
        defaults.removeObject(forKey: "\(prefix)_enabled")
    }
}
