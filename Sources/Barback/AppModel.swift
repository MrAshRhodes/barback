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
    /// The item whose shortcut is being recorded in Settings › Items (`isRecordingHotkey` is true meanwhile).
    @Published var recordingItemHotkey: ItemKey?
    /// Item shortcuts that could not be registered, by item.
    @Published var itemHotkeyErrors: [ItemKey: String] = [:]
    /// Item shortcuts just refused in Settings because another shortcut uses the same keys, by item.
    @Published var itemHotkeyConflicts: [ItemKey: String] = [:]
    @Published var selectedPanelID: UUID?
    /// Shown in the menu and Settings when the separators are in an order that can't be used.
    @Published var layoutWarning: String?

    var onSettingsChange: ((BarbackSettings, BarbackSettings) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    let store: SettingsStore
    let usageReview: UsageReviewModel
    let menuBarDoctor = MenuBarDoctorModel()
    var onProfileSelection: ((UUID?) -> Void)?

    var activeProfile: VisibilityProfile? {
        settings.profiles.first { $0.id == settings.activeProfileID }
    }

    var effectiveGroups: [ItemGroup] {
        VisibilityProfiles.groups(settings.groups, applying: activeProfile)
    }

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.usageReview = UsageReviewModel(defaults: store.defaults)
        self.settings = store.load()
    }

    func selectProfile(_ id: UUID?) {
        if let onProfileSelection { onProfileSelection(id) }
        else { settings.activeProfileID = id }
    }

    var version: String { BarbackInfo.version(from: Bundle.main.infoDictionary) }
    var build: String? { BarbackInfo.build(from: Bundle.main.infoDictionary) }
}
