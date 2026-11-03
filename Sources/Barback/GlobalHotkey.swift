import BarbackCore
import Carbon.HIToolbox
import Foundation

/// One system-wide shortcut via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
///
/// Create one instance per shortcut (the main shortcut, each item's shortcut, …). Every instance gets its own
/// hot key ID, and one shared application event handler routes each press to the instance that registered it.
/// Call `unregister()` before dropping an instance.
@MainActor
final class GlobalHotkey {
    enum HotkeyError: LocalizedError {
        case registrationFailed(OSStatus)
        var errorDescription: String? {
            String(localized: "This shortcut is already used by macOS or another app. Choose a different one.")
        }
    }

    private static let signature: OSType = 0x4242_4B42 // 'BBKB'
    private static var handlerRef: EventHandlerRef?
    private static var nextID: UInt32 = 1
    /// Registered instances by hot key ID. Weak, so a dropped instance can't be called.
    private static var registry: [UInt32: Weak] = [:]

    private struct Weak {
        weak var hotkey: GlobalHotkey?
    }

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    fileprivate var action: (() -> Void)?

    private(set) var combo: KeyCombo?

    init() {
        id = Self.nextID
        Self.nextID &+= 1
    }

    func register(_ combo: KeyCombo, action: @escaping () -> Void) throws {
        unregister()
        Self.installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.rawValue, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.hotkey.error("RegisterEventHotKey failed for \(combo.displayString, privacy: .public): \(status)")
            throw HotkeyError.registrationFailed(status)
        }
        hotKeyRef = ref
        self.combo = combo
        self.action = action
        Self.registry[id] = Weak(hotkey: self)
        Log.hotkey.info("Registered hotkey \(combo.displayString, privacy: .public)")
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        combo = nil
        action = nil
        Self.registry[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hk
            )
            guard status == noErr, hk.signature == GlobalHotkey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hk.id
            // Carbon delivers application-target events on the main thread.
            return MainActor.assumeIsolated {
                guard let action = GlobalHotkey.registry[id]?.hotkey?.action else { return OSStatus(eventNotHandledErr) }
                action()
                return noErr
            }
        }, 1, &spec, nil, &handlerRef)
    }
}
