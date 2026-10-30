import AppKit
import BarbackCore
import SwiftUI

@MainActor
final class PanelEditor: ObservableObject {
    @Published var search = ""
    @Published var error: String?

    func addPanel(to model: AppModel) {
        var settings = model.settings
        guard let id = ItemGroups.add(name: String(localized: "New Panel"), to: &settings.groups) else {
            error = String(localized: "The maximum number of panels has been reached.")
            return
        }
        settings.clickAction = .dropDown
        model.settings = settings
        model.selectedPanelID = id
        error = nil
    }

    func update(_ model: AppModel, change: (inout [ItemGroup]) -> Bool) {
        var groups = model.settings.groups
        let selectedID = groups.first { $0.id == model.selectedPanelID }?.id ?? groups.first?.id
        guard change(&groups) else {
            error = String(localized: "This change could not be saved. Refresh the items and try again.")
            return
        }
        model.settings.groups = groups
        model.selectedPanelID = groups.first { $0.id == selectedID }?.id ?? groups.first?.id
        error = nil
    }
}

struct PanelSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var items: ItemsModel
    @StateObject private var editor = PanelEditor()

    private var groups: [ItemGroup] { model.settings.groups }
    private var selected: ItemGroup? {
        groups.first { $0.id == model.selectedPanelID } ?? groups.first
    }
    private var candidates: [MenuBarItemRow] {
        items.panelCandidates.filter { $0.section != .alwaysHidden || model.settings.alwaysHiddenEnabled }
    }

    var body: some View {
        Form {
            Section {
                Picker("Click Barback to", selection: $model.settings.clickAction) {
                    Text("Show items in the menu bar").tag(ClickAction.revealStrip)
                    Text("Open my panels").tag(ClickAction.dropDown)
                }
            } footer: {
                Text("Panels open together beneath Barback. The keyboard shortcut follows this choice. Option-click still reveals all menu bar items.")
                    .settingsFooter()
            }

            Section {
                HStack {
                    if selected != nil {
                        Picker("Editing", selection: Binding(
                            get: { selected?.id },
                            set: { model.selectedPanelID = $0 }
                        )) {
                            ForEach(groups) { group in
                                Label(group.name, systemImage: group.symbol).tag(Optional(group.id))
                            }
                        }
                    } else {
                        Text("Create a panel, then choose the items it contains.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button { editor.addPanel(to: model) } label: {
                        Label("Add Panel", systemImage: "plus")
                    }
                    .barbackButton()
                    .disabled(groups.count >= ItemGroups.maxGroups)
                }
                if let group = selected {
                    panelDetails(group)
                }
                if let error = editor.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("My Panels")
            } footer: {
                Text("Changes save automatically. Removing a panel or an item here never moves or hides the original menu bar icon.")
                    .settingsFooter()
            }

            if let group = selected {
                selectedItems(group)
                availableItems(group)
            }

            Section {
                HStack {
                    Label(
                        items.accessibilityTrusted ? "Accessibility allowed" : "Accessibility required to open items",
                        systemImage: items.accessibilityTrusted ? "checkmark.circle" : "hand.raised"
                    )
                    Spacer()
                    if !items.accessibilityTrusted {
                        Button("Allow Accessibility...") { items.requestAccessibility() }
                            .barbackButton()
                    }
                }
                HStack {
                    if items.isRefreshing {
                        ProgressView().controlSize(.small)
                        Text("Scanning items...").foregroundStyle(.secondary)
                    } else if items.unidentifiedPanelItemCount > 0 {
                        Text("Some items cannot be identified safely and are not offered for panels.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh Items") { items.refresh() }
                        .barbackButton()
                        .disabled(items.isRefreshing)
                }
            } header: {
                Text("Menu Bar Access")
            } footer: {
                Text("On macOS 26, Accessibility is also needed to identify items hosted by Control Center. After granting it, return here and refresh. Items without a stable identity stay out of panels rather than becoming generic, interchangeable icons.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsMetrics.width, height: 620)
        .onAppear { items.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            items.refreshAccessibilityStatus()
        }
    }

    private func panelDetails(_ group: ItemGroup) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(ItemGroups.symbolPalette, id: \.self) { symbol in
                        Button {
                            editor.update(model) { ItemGroups.setSymbol(symbol, for: group.id, in: &$0) }
                        } label: {
                            Label(Self.symbolTitle(symbol), systemImage: symbol)
                        }
                    }
                } label: {
                    Image(systemName: group.symbol).frame(width: 28, height: 32)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Panel symbol")
                GroupNameField(name: group.name) { name in
                    editor.update(model) { ItemGroups.rename(group.id, to: name, in: &$0) }
                }
                .id(group.id)
                iconButton("Move panel up", symbol: "chevron.up", disabled: groups.first?.id == group.id) {
                    editor.update(model) { ItemGroups.move(group.id, by: -1, in: &$0) }
                }
                iconButton("Move panel down", symbol: "chevron.down", disabled: groups.last?.id == group.id) {
                    editor.update(model) { ItemGroups.move(group.id, by: 1, in: &$0) }
                }
                iconButton("Remove panel", symbol: "trash") {
                    editor.update(model) { ItemGroups.remove(group.id, from: &$0) }
                }
            }
            Picker("Layout", selection: Binding(
                get: { group.layout ?? model.settings.dropDownLayout },
                set: { layout in
                    editor.update(model) { ItemGroups.setLayout(layout, for: group.id, in: &$0) }
                }
            )) {
                Text("List").tag(DropDownLayout.list)
                Text("Grid").tag(DropDownLayout.grid)
            }
            .pickerStyle(.segmented)
        }
    }

    private func selectedItems(_ group: ItemGroup) -> some View {
        Section {
            if group.itemKeys.isEmpty {
                Text("This panel is empty. Add items below to make it yours.")
                    .foregroundStyle(.secondary)
            }
            ForEach(group.itemKeys, id: \.self) { key in
                let row = candidates.first { $0.key == key }
                HStack(spacing: 4) {
                    if let row {
                        itemLabel(row)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.detail ?? key.owner).lineLimit(1)
                            Text("Unavailable - not running or not safely identified")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    iconButton("Move item up", symbol: "chevron.up", disabled: group.itemKeys.first == key) {
                        editor.update(model) { ItemGroups.moveItem(key, in: group.id, by: -1, groups: &$0) }
                    }
                    iconButton("Move item down", symbol: "chevron.down", disabled: group.itemKeys.last == key) {
                        editor.update(model) { ItemGroups.moveItem(key, in: group.id, by: 1, groups: &$0) }
                    }
                    iconButton("Remove item", symbol: "minus.circle") {
                        editor.update(model) { ItemGroups.assign(key, to: nil, in: &$0) }
                    }
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text("Items in \(group.name) (\(group.itemKeys.count))")
        } footer: {
            Text("Use the arrows to set the order shown in this panel. Unavailable selections are kept until you remove them.")
                .settingsFooter()
        }
    }

    private func availableItems(_ group: ItemGroup) -> some View {
        let available = candidates.filter {
            !group.itemKeys.contains($0.key)
                && (editor.search.isEmpty || $0.panelTitle.localizedCaseInsensitiveContains(editor.search))
        }
        return Section {
            TextField("Find an item", text: $editor.search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Find an item to add")
            if available.isEmpty {
                Text(items.isRefreshing ? "Scanning..." : "No matching items available. Check Menu Bar Access below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(available) { row in
                HStack {
                    itemLabel(row)
                    Spacer()
                    Button {
                        editor.update(model) { ItemGroups.assign(row.key, to: group.id, in: &$0) }
                    } label: {
                        let other = groups.first { $0.itemKeys.contains(row.key) }
                        Text(other.map { String(localized: "Move from \($0.name)") } ?? String(localized: "Add"))
                    }
                    .barbackButton()
                    .disabled(group.itemKeys.count >= ItemGroups.maxKeysPerGroup)
                    .accessibilityLabel(Text("Add \(row.panelTitle) to \(group.name)"))
                }
            }
        } header: {
            Text("Add Items")
        } footer: {
            Text("Choose identified items from any menu bar section. Each item belongs to one panel; adding it here moves it from another panel.")
                .settingsFooter()
        }
    }

    private func itemLabel(_ row: MenuBarItemRow) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = ItemIcons.image(for: row.item) {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: ItemIcons.symbol(for: row.item))
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            Text(row.panelTitle).lineLimit(1)
        }
    }

    private func iconButton(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 36, height: 40)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .accessibilityLabel(Text(title))
        .help(title)
    }

    private static func symbolTitle(_ symbol: String) -> String {
        switch symbol {
        case "folder": return String(localized: "Folder")
        case "briefcase": return String(localized: "Briefcase")
        case "gamecontroller": return String(localized: "Game Controller")
        case "music.note": return String(localized: "Music")
        case "play.rectangle": return String(localized: "Video")
        case "bubble.left.and.bubble.right": return String(localized: "Chat")
        case "wrench.and.screwdriver": return String(localized: "Tools")
        case "network": return String(localized: "Network")
        case "lock.shield": return String(localized: "Security")
        case "camera": return String(localized: "Camera")
        case "house": return String(localized: "Home")
        case "star": return String(localized: "Star")
        default: return symbol
        }
    }
}

private struct GroupNameField: View {
    let name: String
    let commit: (String) -> Void
    @StateObject private var field: NameFieldModel
    @FocusState private var focused: Bool

    private final class NameFieldModel: ObservableObject {
        @Published var draft: String
        init(_ name: String) { draft = name }
    }

    init(name: String, commit: @escaping (String) -> Void) {
        self.name = name
        self.commit = commit
        _field = StateObject(wrappedValue: NameFieldModel(name))
    }

    var body: some View {
        TextField("Panel name", text: $field.draft)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .focused($focused)
            .onSubmit(finish)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish() }
            }
            .onChange(of: name) { _, stored in field.draft = stored }
            .accessibilityLabel(Text("Panel name"))
    }

    private func finish() {
        guard field.draft != name else { return }
        let typed = ItemGroups.sanitizedName(field.draft)
        if typed != nil { commit(field.draft) }
        field.draft = typed ?? name
    }
}
