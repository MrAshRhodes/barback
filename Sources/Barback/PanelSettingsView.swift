import AppKit
import BarbackCore
import SwiftUI

// MARK: - Panel

/// Settings › Panel: what clicking Barback does, how the drop-down panel is laid out, and its groups.
struct PanelSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var items: ItemsModel

    private var groups: [ItemGroup] { model.settings.groups }

    var body: some View {
        Form {
            Section {
                Picker("Click Barback to", selection: $model.settings.clickAction) {
                    Text("Show items in the menu bar").tag(ClickAction.revealStrip)
                    Text("Open a drop-down panel").tag(ClickAction.dropDown)
                }
            } header: {
                Text("Click Action")
            } footer: {
                Text(clickFooter).settingsFooter()
            }

            Section {
                Picker("Layout", selection: $model.settings.dropDownLayout) {
                    Text("List").tag(DropDownLayout.list)
                    Text("Grid").tag(DropDownLayout.grid)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Panel Layout")
            } footer: {
                Text("A list shows each item’s name. A grid shows just the icons, which fit more items in less space.")
                    .settingsFooter()
            }

            Section {
                if groups.isEmpty {
                    Text("No groups yet. Add some, then right-click an item in the panel to move it into one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groups) { group in
                        GroupRow(
                            group: group,
                            isFirst: group.id == groups.first?.id,
                            isLast: group.id == groups.last?.id,
                            update: update
                        )
                    }
                }
                HStack {
                    addGroupMenu
                    Spacer()
                    Text("\(groups.count) of \(ItemGroups.maxGroups)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("Groups")
            } footer: {
                Text("Items that aren’t in a group appear under Other. Groups with no hidden items are left out of the panel, and deleting a group never hides or moves anything in the menu bar.")
                    .settingsFooter()
            }

            Section {
                LabeledContent("Accessibility") {
                    if items.accessibilityTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Text("Not allowed").foregroundStyle(.secondary)
                            Button("Allow…") { items.requestAccessibility() }
                                .barbackButton()
                        }
                    }
                }
            } header: {
                Text("Opening Items")
            } footer: {
                Text("With Accessibility allowed, choosing an item in the panel also opens that item’s menu. Without it, choosing an item shows the hidden items in the menu bar instead.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsMetrics.width, height: 560)
        .onAppear { items.refreshAccessibilityStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            items.refreshAccessibilityStatus()
        }
    }

    private var clickFooter: String {
        var text = String(localized: "Option-click Barback to show every item in the menu bar, including always-hidden ones.")
        if model.settings.clickAction == .dropDown {
            text += " " + String(localized: "The keyboard shortcut opens the panel too.")
        }
        return text
    }

    // MARK: Editing

    /// Applies `change` to a copy of the groups and stores the result (which also saves it).
    private func update(_ change: (inout [ItemGroup]) -> Void) {
        var copy = model.settings.groups
        change(&copy)
        model.settings.groups = copy
    }

    private var suggestionsToOffer: [(name: String, symbol: String)] {
        let taken = Set(groups.map { $0.name.lowercased() })
        return ItemGroups.suggestions.filter { !taken.contains($0.name.lowercased()) }
    }

    private var addGroupMenu: some View {
        Menu {
            ForEach(suggestionsToOffer, id: \.name) { suggestion in
                Button {
                    update { ItemGroups.add(name: suggestion.name, symbol: suggestion.symbol, to: &$0) }
                } label: {
                    Label(suggestion.name, systemImage: suggestion.symbol)
                }
            }
            if !suggestionsToOffer.isEmpty { Divider() }
            Button("New Group") {
                update { ItemGroups.add(name: String(localized: "New Group"), to: &$0) }
            }
        } label: {
            Label("Add Group", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(groups.count >= ItemGroups.maxGroups)
    }
}

// MARK: - One group

private struct GroupRow: View {
    let group: ItemGroup
    let isFirst: Bool
    let isLast: Bool
    let update: (_ change: (inout [ItemGroup]) -> Void) -> Void

    var body: some View {
        HStack(spacing: 8) {
            symbolMenu
            GroupNameField(name: group.name) { draft in
                update { ItemGroups.rename(group.id, to: draft, in: &$0) }
            }
            Button {
                update { ItemGroups.move(group.id, by: -1, in: &$0) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(isFirst)
            .accessibilityLabel(Text("Move \(group.name) up"))
            .help(Text("Move up"))
            Button {
                update { ItemGroups.move(group.id, by: 1, in: &$0) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(isLast)
            .accessibilityLabel(Text("Move \(group.name) down"))
            .help(Text("Move down"))
            Button(role: .destructive) {
                update { ItemGroups.remove(group.id, from: &$0) }
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel(Text("Delete \(group.name)"))
            .help(Text("Delete group"))
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
    }

    private var symbolMenu: some View {
        Menu {
            ForEach(ItemGroups.symbolPalette, id: \.self) { symbol in
                Button {
                    update { ItemGroups.setSymbol(symbol, for: group.id, in: &$0) }
                } label: {
                    Label(Self.symbolTitle(symbol), systemImage: symbol)
                }
            }
        } label: {
            Image(systemName: group.symbol)
                .frame(width: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Symbol for \(group.name)"))
        .help(Text("Change symbol"))
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

/// Edits a group's name in place; the change is saved on Return or when the field loses focus.
private struct GroupNameField: View {
    let name: String
    let commit: (String) -> Void
    @StateObject private var field: NameFieldModel
    @FocusState private var focused: Bool

    /// Holds the text being typed. (Stands in for `@State`; see `PanelItemButtonStyle`.)
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
        TextField("Group name", text: $field.draft)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .focused($focused)
            .onSubmit(finish)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish() }
            }
            // The stored name may differ from what was typed (trimmed, shortened or numbered to stay unique).
            .onChange(of: name) { _, stored in field.draft = stored }
            .accessibilityLabel(Text("Group name"))
    }

    private func finish() {
        guard field.draft != name else { return }
        let typed = ItemGroups.sanitizedName(field.draft)
        if typed != nil { commit(field.draft) }
        // Shows the trimmed text at once; a different stored name (made unique) arrives through `name`.
        field.draft = typed ?? name
    }
}
