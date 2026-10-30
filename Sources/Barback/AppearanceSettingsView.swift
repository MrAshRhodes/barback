import AppKit
import BarbackCore
import SwiftUI

// MARK: - Appearance

/// Styles for Barback's own items. Nothing here touches other apps' menu bar items.
struct AppearanceSettingsView: View {
    @ObservedObject var model: AppModel

    private var appearance: Binding<AppearanceSettings> { $model.settings.appearance }

    /// Picking a style changes the icon and separators; any other change makes the style "Custom" (nil).
    private var style: Binding<AppearanceStyle?> {
        Binding(
            get: { model.settings.appearance.style },
            set: { if let style = $0 { model.settings.appearance.apply(style) } }
        )
    }

    var body: some View {
        let current = model.settings.appearance
        Form {
            Section {
                MenuBarPreview(appearance: current, alwaysHiddenEnabled: model.settings.alwaysHiddenEnabled)
            } header: {
                Text("Preview")
            }

            Section {
                Picker("Style", selection: style) {
                    ForEach(AppearanceStyle.allCases) { style in
                        Text(style.displayName).tag(Optional(style))
                    }
                    if current.style == nil {
                        Divider()
                        Text("Custom").tag(AppearanceStyle?.none)
                    }
                }
                Picker("Icon", selection: appearance.toggleIcon) {
                    ForEach(ToggleIconStyle.allCases) { icon in
                        Label(icon.displayName, systemImage: icon.symbolName(revealed: false)).tag(icon)
                    }
                }
                Picker("Weight", selection: appearance.iconWeight) {
                    ForEach(IconWeight.allCases) { weight in
                        Text(weight.displayName).tag(weight)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Tint the icon while hidden items are showing", isOn: appearance.tintWhenShowing)
            } header: {
                Text("Barback Icon")
            } footer: {
                Text("Styles change only Barback’s own icon and separators. The icon also changes shape when hidden items are showing.")
                    .settingsFooter()
            }

            Section {
                Picker("Hidden section", selection: appearance.hiddenDivider) {
                    dividerOptions
                }
                Picker("Always-hidden section", selection: appearance.alwaysHiddenDivider) {
                    dividerOptions
                }
                .disabled(!model.settings.alwaysHiddenEnabled)
            } header: {
                Text("Separators")
            } footer: {
                Text(separatorFooter).settingsFooter()
            }

            Section {
                LabeledContent("Extra dividers") {
                    HStack(spacing: 8) {
                        Text(current.extraDividerCount, format: .number)
                            .monospacedDigit()
                        Stepper("Extra dividers", value: appearance.extraDividerCount, in: 0...AppearanceSettings.maxExtraDividers)
                            .labelsHidden()
                    }
                }
                Picker("Divider style", selection: appearance.extraDividerStyle) {
                    dividerOptions
                }
                .disabled(current.extraDividerCount == 0)
            } header: {
                Text("Dividers")
            } footer: {
                Text("Dividers help group menu bar items; they don’t hide anything. New dividers appear next to Barback. Hold ⌘ and drag them where you want.")
                    .settingsFooter()
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { model.settings.appearance = .default }
                        .barbackButton()
                        .disabled(current == .default)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var dividerOptions: some View {
        ForEach(DividerStyle.allCases) { style in
            Text(style.displayName).tag(style)
        }
    }

    private var separatorFooter: String {
        var text = String(localized: "An invisible separator leaves a narrow gap that you can still hold ⌘ and drag.")
        if !model.settings.alwaysHiddenEnabled {
            text += " " + String(localized: "Turn on the always-hidden section in General to use its separator.")
        }
        return text
    }
}

// MARK: - Live preview

/// A miniature menu bar showing Barback's items in each state with the current appearance.
private struct MenuBarPreview: View {
    let appearance: AppearanceSettings
    let alwaysHiddenEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(String(localized: "Hidden"), state: .hidden)
            row(String(localized: "Showing"), state: .shown)
            if alwaysHiddenEnabled {
                row(String(localized: "Showing all"), state: .shownAll)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ title: String, state: SectionState) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            strip(state)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(accessibilityDescription(state)))
    }

    private func strip(_ state: SectionState) -> some View {
        HStack(spacing: 10) {
            if state == .shownAll {
                fakeItem("lock")
                divider(appearance.alwaysHiddenDivider)
            }
            if state.isRevealed {
                fakeItem("cloud")
                fakeItem("music.note")
                divider(appearance.hiddenDivider)
            }
            fakeItem("wifi")
            if appearance.extraDividerCount > 0 {
                ForEach(0..<appearance.extraDividerCount, id: \.self) { _ in
                    divider(appearance.extraDividerStyle)
                }
            }
            fakeItem("battery.75")
            toggle(revealed: state.isRevealed)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 24)
        .menuBarStripBackground()
    }

    private func fakeItem(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func divider(_ style: DividerStyle) -> some View {
        if let image = StatusIcons.dividerImage(style: style, label: style.displayName) {
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(.primary)
        } else {
            Color.clear.frame(width: DividerStyle.invisibleLength, height: 16)
        }
    }

    @ViewBuilder
    private func toggle(revealed: Bool) -> some View {
        if let image = StatusIcons.toggleImage(
            style: appearance.toggleIcon, weight: appearance.iconWeight, revealed: revealed, label: nil
        ) {
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(appearance.tintWhenShowing && revealed ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
    }

    private func accessibilityDescription(_ state: SectionState) -> String {
        var parts: [String] = []
        if state == .shownAll {
            parts.append(String(localized: "always-hidden items, \(appearance.alwaysHiddenDivider.displayName) separator"))
        }
        if state.isRevealed {
            parts.append(String(localized: "hidden items, \(appearance.hiddenDivider.displayName) separator"))
        }
        parts.append(String(localized: "visible items"))
        if appearance.extraDividerCount > 0 {
            parts.append(String(localized: "extra dividers: \(appearance.extraDividerCount), \(appearance.extraDividerStyle.displayName)"))
        }
        parts.append(String(localized: "\(appearance.toggleIcon.displayName) icon"))
        return parts.joined(separator: ", ")
    }
}

private extension View {
    /// Liquid Glass strip on macOS 26; a bar material strip before.
    @ViewBuilder
    func menuBarStripBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.bar, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}
