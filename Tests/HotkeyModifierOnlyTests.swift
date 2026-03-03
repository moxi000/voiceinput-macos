import Testing
import Cocoa
@testable import VoiceInput

struct HotkeyModifierOnlyTests {
    @Test("Modifier-only hold 状态机：保持目标修饰键时不应误停，仅在释放后停止")
    func modifierOnlyHoldMachineStopsOnlyOnRelease() {
        var machine = HotkeyManager.ModifierOnlyHoldMachine()
        machine.activate(requiredModifiers: .maskAlternate)

        #expect(machine.shouldStop(on: .maskAlternate) == false)
        #expect(machine.shouldStop(on: [.maskAlternate, .maskShift]) == false)
        #expect(machine.shouldStop(on: []) == true)
    }

    @Test("热键保存校验：禁用时允许保存空配置")
    func saveValidationAllowsDisable() {
        let result = HotkeySaveValidator.validate(disabled: true, pending: nil, other: nil)
        #expect(result == .valid(nil))
    }

    @Test("热键保存校验：未录入时禁止保存")
    func saveValidationRejectsEmptyPendingWhenEnabled() {
        let result = HotkeySaveValidator.validate(disabled: false, pending: nil, other: nil)
        #expect(result == .invalid(.notRecorded))
    }

    @Test("热键保存校验：同组合冲突检测")
    func saveValidationDetectsConflict() {
        let pending = HotkeyConfig(keyCode: 6, modifiers: .maskAlternate)
        let other = HotkeyConfig(keyCode: 6, modifiers: .maskAlternate)
        let conflict = HotkeySaveValidator.hasConflict(pending, other)
        let result = HotkeySaveValidator.validate(disabled: false, pending: pending, other: other)

        #expect(conflict == true)
        #expect(result == .invalid(.conflict))
    }

    @Test("热键保存校验：不同组合不冲突")
    func saveValidationNoConflictForDifferentCombo() {
        let pending = HotkeyConfig(keyCode: 6, modifiers: .maskAlternate)
        let other = HotkeyConfig(keyCode: 7, modifiers: .maskAlternate)
        let conflict = HotkeySaveValidator.hasConflict(pending, other)
        let result = HotkeySaveValidator.validate(disabled: false, pending: pending, other: other)

        #expect(conflict == false)
        #expect(result == .valid(pending))
    }
}
