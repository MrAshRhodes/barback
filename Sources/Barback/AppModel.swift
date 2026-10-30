import BarbackCore
import Combine
import Foundation

/// Shared observable state for the settings UI and controllers.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: BarbackSettings {
        didSet {
            let sanitized = settings.sanitized()
            if sanitized != settings {
                settings = sanitized
                return
            }
            guard settings != oldValue else { return }
            store.save(settings)
            onSettingsChange?(oldValue, settings)
        }
    }

    /// True while the shortcut recorder is capturing keys (the global hotkey is suspended meanwhile).
    @Published var isRecordingHotkey = false {
        didSet { if isRecordingHotkey != oldValue { onRecordingChange?(isRecordingHotkey) } }
    }

    @Published var hotkeyError: String?
    /// Shown in the menu and Settings when the separators are in an order that can't be used.
    @Published var layoutWarning: String?

    var onSettingsChange: ((BarbackSettings, BarbackSettings) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.settings = store.load()
    }

    var version: String { BarbackInfo.version(from: Bundle.main.infoDictionary) }
    var build: String? { BarbackInfo.build(from: Bundle.main.infoDictionary) }
}
