import AppKit
import BarbackCore
import SwiftUI

struct ProfileSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var items: ItemsModel
    @StateObject private var editor = ProfileEditor()

    private final class ProfileEditor: ObservableObject {
        @Published var editingID: UUID?
        @Published var error: String?
    }

    private var selected: VisibilityProfile? {
        model.settings.profiles.first { $0.id == editor.editingID } ?? model.settings.profiles.first
    }

    var body: some View {
        Form {
            Section {
                Picker("Active profile", selection: Binding(
                    get: { model.settings.activeProfileID }, set: { model.selectProfile($0) }
                )) {
                    Text("Base configuration").tag(Optional<UUID>.none)
                    ForEach(model.settings.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Base section visibility", selection: $model.settings.baseVisibility) {
                    ForEach(ProfileVisibility.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Profiles change Barback's sections and panel membership, not individual icons in the physical menu bar. Arrange those manually with Command-drag. Auto-rehide still applies.")
                    .settingsFooter()
                Text("Manual selection lasts until the next display or other-app change. App rules win over display-only rules; earlier profiles win ties. When no profile matches, Barback returns to the base visibility. Rule edits take effect at the next change.")
                    .settingsFooter()
            }

            Section("Profiles (highest priority first)") {
                HStack {
                    Button("Add Profile") { add() }
                        .disabled(model.settings.profiles.count >= VisibilityProfiles.maxProfiles)
                    if let selected {
                        Button("Delete Profile", role: .destructive) { delete(selected.id) }
                    }
                }
                if let selected {
                    Picker("Editing profile", selection: Binding(
                        get: { selected.id }, set: { editor.editingID = $0 }
                    )) {
                        ForEach(model.settings.profiles) { Text($0.name).tag($0.id) }
                    }
                    LabeledContent("Name") {
                        GroupNameField(name: selected.name, label: "Profile name") { name in edit { $0.name = name } }
                            .id(selected.id)
                    }
                    Picker("Section visibility", selection: binding(\.visibility, fallback: selected.visibility)) {
                        ForEach(ProfileVisibility.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Button("Higher Priority") { move(selected.id, by: -1) }
                            .disabled(model.settings.profiles.first?.id == selected.id)
                        Button("Lower Priority") { move(selected.id, by: 1) }
                            .disabled(model.settings.profiles.last?.id == selected.id)
                    }
                    Toggle("Switch automatically when conditions match", isOn: binding(\.automatic, fallback: false))
                    if selected.automatic {
                        TextField("Frontmost app bundle identifier (optional)", text: binding(\.appBundleID, fallback: ""))
                            .help("For example, com.apple.Safari. Leave empty for a display-only rule.")
                        Picker("Display condition", selection: binding(\.displayCondition, fallback: .any)) {
                            ForEach(ProfileDisplayCondition.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Display count", selection: binding(\.displayCount, fallback: nil)) {
                            Text("Any count").tag(Optional<Int>.none)
                            ForEach(1...32, id: \.self) { Text("\($0)").tag(Optional($0)) }
                        }
                        if selected.appBundleID.isEmpty, selected.displayCondition == .any, selected.displayCount == nil {
                            Text("Choose at least one condition to enable automatic matching.").settingsFooter()
                        }
                    }
                } else {
                    Text("No profiles. Existing visibility behavior is unchanged.").foregroundStyle(.secondary)
                }
                if let error = editor.error { Text(error).foregroundStyle(.red) }
            }

            if let selected {
                Section("Items visible in panels for \(selected.name)") {
                    if model.settings.groups.allSatisfy({ $0.itemKeys.isEmpty }) {
                        Text("Configure items in the Panel tab first. Profiles keep that base configuration intact.")
                            .settingsFooter()
                    }
                    ForEach(model.settings.groups) { group in
                        ForEach(group.itemKeys, id: \.self) { key in
                            let name = items.panelCandidates.first { $0.key == key }?.panelTitle ?? key.linkIdentifier
                            Toggle("\(group.name): \(name)", isOn: Binding(
                                get: { !selected.excludedPanelItems.contains(key) },
                                set: { shown in
                                    edit { profile in
                                        profile.excludedPanelItems.removeAll { $0 == key }
                                        if !shown { profile.excludedPanelItems.append(key) }
                                    }
                                }
                            ))
                        }
                    }
                    Text("Unchecked items remain configured and can still be opened with their shortcuts or links. Missing items are skipped without changing other items.")
                        .settingsFooter()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsMetrics.width, height: 520)
    }

    private func binding<Value>(_ path: WritableKeyPath<VisibilityProfile, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { selected?[keyPath: path] ?? fallback }, set: { value in edit { $0[keyPath: path] = value } })
    }

    private func edit(_ change: (inout VisibilityProfile) -> Void) {
        guard let id = selected?.id, let index = model.settings.profiles.firstIndex(where: { $0.id == id }) else {
            editor.error = String(localized: "The profile is no longer available.")
            return
        }
        var profiles = model.settings.profiles
        change(&profiles[index])
        model.settings.profiles = profiles
    }

    private func add() {
        guard model.settings.profiles.count < VisibilityProfiles.maxProfiles else {
            editor.error = String(localized: "The maximum number of profiles has been reached.")
            return
        }
        let profile = VisibilityProfile(name: String(localized: "Profile \(model.settings.profiles.count + 1)"))
        model.settings.profiles.append(profile)
        editor.editingID = profile.id
        editor.error = nil
    }

    private func delete(_ id: UUID) {
        if model.settings.activeProfileID == id { model.selectProfile(nil) }
        model.settings.profiles.removeAll { $0.id == id }
        editor.editingID = model.settings.profiles.first?.id
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = model.settings.profiles.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard model.settings.profiles.indices.contains(destination) else { return }
        model.settings.profiles.swapAt(index, destination)
    }
}
