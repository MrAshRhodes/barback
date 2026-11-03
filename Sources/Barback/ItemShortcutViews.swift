import AppKit
import BarbackCore
import SwiftUI

/// Settings glue for item shortcuts and `barback://open` links.
@MainActor
enum ItemShortcutSettings {
    /// "… is already used by …" for a refused shortcut.
    static func conflictMessage(_ combo: KeyCombo, with target: HotkeyTarget, in settings: BarbackSettings) -> String {
        let shortcut = combo.displayString
        switch target {
        case .main:
            return String(localized: "\(shortcut) is already the Show or hide items shortcut. Choose a different one.")
        case .item(let key):
            let name = settings.itemHotkey(for: key)?.displayTitle ?? key.linkIdentifier
            return String(localized: "\(shortcut) already opens \(name). Choose a different one.")
        case .named(let name):
            return String(localized: "\(shortcut) is already used by \(name). Choose a different one.")
        }
    }

    /// The main shortcut, refusing combinations an item shortcut already uses.
    static func mainHotkeyBinding(_ model: AppModel) -> Binding<KeyCombo?> {
        Binding(
            get: { model.settings.hotkey },
            set: { combo in
                if let combo, let other = HotkeyConflicts.conflict(for: combo, target: .main, in: model.settings.hotkeyAssignments) {
                    NSSound.beep()
                    model.hotkeyError = conflictMessage(combo, with: other, in: model.settings)
                    return
                }
                model.settings.hotkey = combo
            }
        )
    }

    /// True only while the main recorder (not an item's) is recording.
    static func mainRecordingBinding(_ model: AppModel) -> Binding<Bool> {
        Binding(
            get: { model.isRecordingHotkey && model.recordingItemHotkey == nil },
            set: { model.isRecordingHotkey = $0 }
        )
    }

    static func copyLink(for key: ItemKey) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(key.openURL.absoluteString, forType: .string)
    }
}

/// Shortcut recorder and Copy Link button for one item in Settings › Items.
struct ItemShortcutControls: View {
    @ObservedObject var model: AppModel
    let key: ItemKey
    let title: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                HotkeyRecorder(combo: comboBinding, isRecording: recordingBinding)
                    .accessibilityLabel(Text("Shortcut for \(title)"))
                Button {
                    ItemShortcutSettings.copyLink(for: key)
                } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Copy link to \(title)"))
                .help(Text("Copy a barback://open link that opens this item"))
            }
            if let message = model.itemHotkeyConflicts[key] ?? model.itemHotkeyErrors[key] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var comboBinding: Binding<KeyCombo?> {
        Binding(
            get: { model.settings.itemHotkey(for: key)?.combo },
            set: { combo in
                var settings = model.settings
                if let combo, let other = settings.setItemHotkey(combo, for: key, title: title) {
                    NSSound.beep()
                    model.itemHotkeyConflicts[key] = ItemShortcutSettings.conflictMessage(combo, with: other, in: settings)
                    return
                }
                if combo == nil { settings.setItemHotkey(nil, for: key, title: title) }
                model.itemHotkeyConflicts[key] = nil
                model.settings = settings
            }
        )
    }

    private var recordingBinding: Binding<Bool> {
        Binding(
            get: { model.recordingItemHotkey == key },
            set: { recording in
                if recording {
                    model.recordingItemHotkey = key
                    model.isRecordingHotkey = true
                } else if model.recordingItemHotkey == key {
                    model.recordingItemHotkey = nil
                    model.isRecordingHotkey = false
                }
            }
        )
    }
}

/// Every saved item shortcut, including items that aren't in the menu bar right now, so they can be removed.
struct ItemShortcutsSection: View {
    @ObservedObject var model: AppModel
    /// Keys of items currently in the menu bar.
    let presentKeys: Set<ItemKey>

    var body: some View {
        if !model.settings.itemHotkeys.isEmpty {
            Section {
                ForEach(model.settings.itemHotkeys, id: \.key) { hotkey in
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(hotkey.combo.displayString)
                                .monospacedDigit()
                                .accessibilityLabel(Text(hotkey.combo.accessibilityDescription))
                            Button {
                                ItemShortcutSettings.copyLink(for: hotkey.key)
                            } label: {
                                Image(systemName: "link")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Copy link to \(hotkey.displayTitle)"))
                            .help(Text("Copy a barback://open link that opens this item"))
                            Button {
                                model.settings.setItemHotkey(nil, for: hotkey.key, title: nil)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Remove shortcut for \(hotkey.displayTitle)"))
                            .help(Text("Remove shortcut"))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hotkey.displayTitle)
                            if !presentKeys.contains(hotkey.key) {
                                Text("Not in the menu bar right now")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let error = model.itemHotkeyErrors[hotkey.key] {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            } header: {
                Text("Item Shortcuts")
            } footer: {
                Text("Each shortcut opens its item’s menu, revealing it first if it’s hidden. Needs Accessibility access. Shortcuts for items that aren’t in the menu bar do nothing.")
                    .settingsFooter()
            }
        }
    }
}
