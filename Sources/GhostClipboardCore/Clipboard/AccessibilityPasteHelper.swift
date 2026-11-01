import Foundation
import AppKit
import ApplicationServices
import Carbon

// MARK: - Accessibility & Direct Paste Synthesis Helper

public enum AccessibilityPasteHelper {

    /// Returns whether GhostClipboard currently has macOS Accessibility trust (`AXIsProcessTrusted()`).
    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Requests macOS Accessibility permission, optionally triggering the system prompt dialog.
    @discardableResult
    public static func requestAccessibilityPermission(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens macOS System Settings -> Privacy & Security -> Accessibility directly.
    public static func openAccessibilitySystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Synthesizes a native Command+V (`0x09` virtual key with `.maskCommand`) keystroke to the active application.
    @discardableResult
    public static func synthesizeCommandVPaste() -> Bool {
        guard isAccessibilityTrusted else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)

        let vKeyCode: CGKeyCode = 0x09 // kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Reactivates the previous external application and optionally synthesizes `⌘V` after a 40ms activation delay.
    public static func reactivateAndPasteIfNeeded(
        previousApp: NSRunningApplication?,
        directPasteEnabled: Bool,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        if let app = previousApp, !app.isTerminated {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        guard directPasteEnabled && isAccessibilityTrusted else {
            completion?(false)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) {
            let posted = synthesizeCommandVPaste()
            completion?(posted)
        }
    }
}

// MARK: - Global Shortcut KeyCode & Modifier Formatter

public struct HotkeyPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let displayString: String

    public init(id: String, title: String, keyCode: UInt32, carbonModifiers: UInt32, displayString: String) {
        self.id = id
        self.title = title
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayString = displayString
    }
}

public enum ShortcutFormatter {
    public static let carbonCmdKey: UInt32     = UInt32(cmdKey)     // 256
    public static let carbonShiftKey: UInt32   = UInt32(shiftKey)   // 512
    public static let carbonOptionKey: UInt32  = UInt32(optionKey)  // 2048
    public static let carbonControlKey: UInt32 = UInt32(controlKey) // 4096

    public static let presets: [HotkeyPreset] = [
        HotkeyPreset(
            id: "opt_space",
            title: "⌥Space",
            keyCode: 49,
            carbonModifiers: carbonOptionKey,
            displayString: "⌥Space"
        ),
        HotkeyPreset(
            id: "shift_cmd_v",
            title: "⇧⌘V",
            keyCode: 9,
            carbonModifiers: carbonShiftKey | carbonCmdKey,
            displayString: "⇧⌘V"
        ),
        HotkeyPreset(
            id: "ctrl_opt_space",
            title: "⌃⌥Space",
            keyCode: 49,
            carbonModifiers: carbonControlKey | carbonOptionKey,
            displayString: "⌃⌥Space"
        ),
        HotkeyPreset(
            id: "ctrl_shift_v",
            title: "⌃⇧V",
            keyCode: 9,
            carbonModifiers: carbonControlKey | carbonShiftKey,
            displayString: "⌃⇧V"
        )
    ]

    public static func isModifierOnlyKeyCode(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand,
             kVK_Shift, kVK_RightShift,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_CapsLock, kVK_Function:
            return true
        default:
            return false
        }
    }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= carbonControlKey }
        if flags.contains(.option)  { mods |= carbonOptionKey }
        if flags.contains(.shift)   { mods |= carbonShiftKey }
        if flags.contains(.command) { mods |= carbonCmdKey }
        return mods
    }

    public static func displayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var parts = ""
        if (carbonModifiers & carbonControlKey) != 0 { parts += "⌃" }
        if (carbonModifiers & carbonOptionKey) != 0  { parts += "⌥" }
        if (carbonModifiers & carbonShiftKey) != 0   { parts += "⇧" }
        if (carbonModifiers & carbonCmdKey) != 0     { parts += "⌘" }
        parts += keyName(for: keyCode)
        return parts
    }

    public static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        default: return "Key\(keyCode)"
        }
    }
}
