import Foundation

/// Hotkey modifiers stored with Carbon bit values, so `rawValue` can be passed straight to `RegisterEventHotKey`.
public struct HotkeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    // Carbon (HIToolbox/Events.h) values: cmdKey, shiftKey, optionKey, controlKey.
    public static let command = HotkeyModifiers(rawValue: 0x0100)
    public static let shift = HotkeyModifiers(rawValue: 0x0200)
    public static let option = HotkeyModifiers(rawValue: 0x0800)
    public static let control = HotkeyModifiers(rawValue: 0x1000)

    // NSEvent.ModifierFlags raw values (kept here so the core stays AppKit-free).
    public static let cocoaShift: UInt = 1 << 17
    public static let cocoaControl: UInt = 1 << 18
    public static let cocoaOption: UInt = 1 << 19
    public static let cocoaCommand: UInt = 1 << 20

    /// Converts `NSEvent.ModifierFlags.rawValue` to Carbon modifiers, ignoring Caps Lock, Fn, etc.
    public init(cocoaFlags: UInt) {
        var m: HotkeyModifiers = []
        if cocoaFlags & Self.cocoaControl != 0 { m.insert(.control) }
        if cocoaFlags & Self.cocoaOption != 0 { m.insert(.option) }
        if cocoaFlags & Self.cocoaShift != 0 { m.insert(.shift) }
        if cocoaFlags & Self.cocoaCommand != 0 { m.insert(.command) }
        self = m
    }

    /// The equivalent `NSEvent.ModifierFlags.rawValue`.
    public var cocoaFlags: UInt {
        var f: UInt = 0
        if contains(.control) { f |= Self.cocoaControl }
        if contains(.option) { f |= Self.cocoaOption }
        if contains(.shift) { f |= Self.cocoaShift }
        if contains(.command) { f |= Self.cocoaCommand }
        return f
    }

    /// Glyphs in the order macOS menus use: ⌃ ⌥ ⇧ ⌘.
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }

    /// Spoken form for VoiceOver, e.g. "Control-Option-Command".
    public var spokenNames: [String] {
        var n: [String] = []
        if contains(.control) { n.append("Control") }
        if contains(.option) { n.append("Option") }
        if contains(.shift) { n.append("Shift") }
        if contains(.command) { n.append("Command") }
        return n
    }
}

/// A global shortcut: virtual key code (kVK_*) plus modifiers.
public struct KeyCombo: Hashable, Codable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌃⌥⌘B
    public static let defaultToggle = KeyCombo(keyCode: KeyCodes.b, modifiers: [.control, .option, .command])

    /// e.g. "⌃⌥⌘B".
    public var displayString: String { modifiers.symbols + KeyCodes.name(for: keyCode) }

    /// e.g. "Control-Option-Command-B".
    public var accessibilityDescription: String {
        (modifiers.spokenNames + [KeyCodes.spokenName(for: keyCode)]).joined(separator: "-")
    }

    /// A global hotkey needs ⌘, ⌃ or ⌥ (Shift alone would swallow normal typing), unless it is a function key.
    public var isValidGlobalHotkey: Bool {
        if KeyCodes.isFunctionKey(keyCode) { return true }
        if KeyCodes.isModifierKey(keyCode) { return false }
        return !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    /// Lowercase character usable as an `NSMenuItem.keyEquivalent`, when the key maps to one.
    public var menuKeyEquivalent: String? { KeyCodes.character(for: keyCode) }
}

/// ANSI virtual key codes (Carbon `kVK_*`) and their display names.
public enum KeyCodes {
    public static let b: UInt32 = 11
    public static let escape: UInt32 = 53
    public static let delete: UInt32 = 51
    public static let forwardDelete: UInt32 = 117

    private static let characters: [UInt32: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ]

    private static let specialNames: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 115: "↖", 119: "↘",
        116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑", 76: "⌤",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let spokenSpecial: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 117: "Forward Delete",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 123: "Left Arrow",
        124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow", 76: "Enter",
    ]

    private static let functionKeys: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// Shift, Command, Option, Control, Caps Lock, Fn and their right-hand variants.
    private static let modifierKeys: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    public static func character(for code: UInt32) -> String? { characters[code] }

    public static func name(for code: UInt32) -> String {
        if let c = characters[code] { return c.uppercased() }
        return specialNames[code] ?? "Key \(code)"
    }

    public static func spokenName(for code: UInt32) -> String {
        if let s = spokenSpecial[code] { return s }
        return name(for: code)
    }

    public static func isFunctionKey(_ code: UInt32) -> Bool { functionKeys.contains(code) }
    public static func isModifierKey(_ code: UInt32) -> Bool { modifierKeys.contains(code) }
}
