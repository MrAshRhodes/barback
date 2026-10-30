import BarbackCore
import Carbon.HIToolbox
import Foundation

/// A single system-wide shortcut via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
@MainActor
final class GlobalHotkey {
    enum HotkeyError: LocalizedError {
        case registrationFailed(OSStatus)
        var errorDescription: String? {
            String(localized: "This shortcut is already used by macOS or another app. Choose a different one.")
        }
    }

    private static let signature: OSType = 0x4242_4B42 // 'BBKB'
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate var action: (() -> Void)?

    private(set) var combo: KeyCombo?

    func register(_ combo: KeyCombo, action: @escaping () -> Void) throws {
        unregister()
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.rawValue, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.hotkey.error("RegisterEventHotKey failed for \(combo.displayString, privacy: .public): \(status)")
            throw HotkeyError.registrationFailed(status)
        }
        hotKeyRef = ref
        self.combo = combo
        self.action = action
        Log.hotkey.info("Registered hotkey \(combo.displayString, privacy: .public)")
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        combo = nil
        action = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hk = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hk
            )
            guard status == noErr, hk.signature == GlobalHotkey.signature, let userData else {
                return OSStatus(eventNotHandledErr)
            }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { hotkey.action?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }
}
