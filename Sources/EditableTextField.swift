import Cocoa

/// NSTextField 子类，修复菜单栏应用中 Cmd+V/C/X/A 快捷键不生效的问题。
/// 原因：菜单栏应用没有标准 Edit 菜单，快捷键无法通过菜单项路由。
class EditableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v":
                return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "c":
                return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "x":
                return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case "a":
                return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            case "z":
                if event.modifierFlags.contains(.shift) {
                    return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
                }
                return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// NSSecureTextField 子类，同上。
class EditableSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v":
                return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "a":
                return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            // 密码框不支持复制/剪切，仅粘贴和全选
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
