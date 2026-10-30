import AppKit
import BarbackCore
import SwiftUI

// MARK: - Liquid Glass with pre-Tahoe fallbacks

extension View {
    /// Prominent action button: Liquid Glass on macOS 26, bordered prominent before.
    @ViewBuilder
    func barbackProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Secondary action button: Liquid Glass on macOS 26, bordered before.
    @ViewBuilder
    func barbackButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

enum SettingsMetrics {
    static let width: CGFloat = 520
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var loginItem: LoginItemController

    private var rehideOptions: [Int] {
        var options = BarbackSettings.autoRehidePresets
        if !options.contains(model.settings.autoRehideSeconds) {
            options.append(model.settings.autoRehideSeconds)
            options.sort()
        }
        return options
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.status == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items Settings…") { loginItem.openSystemSettings() }
                            .barbackButton()
                    } label: {
                        Label("Approval needed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loginItem.statusText)
                    if let error = loginItem.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .settingsFooter()
            }

            Section {
                Picker("Hide items again", selection: $model.settings.autoRehideSeconds) {
                    ForEach(rehideOptions, id: \.self) { seconds in
                        Text(Self.rehideLabel(seconds)).tag(seconds)
                    }
                }
                Toggle("Show hidden items when hovering over the menu bar", isOn: $model.settings.showOnHover)
                Toggle("Hide items again when switching apps", isOn: $model.settings.rehideOnAppSwitch)
                Toggle("Always-hidden section", isOn: $model.settings.alwaysHiddenEnabled)
            } header: {
                Text("Hiding")
            } footer: {
                Text(hidingFooter).settingsFooter()
            }

            Section {
                LabeledContent("Show or hide items") {
                    HotkeyRecorder(combo: $model.settings.hotkey, isRecording: $model.isRecordingHotkey)
                }
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Click the shortcut, then press a new key combination that includes ⌘, ⌥ or ⌃. Press Delete to remove it or Escape to cancel.")
                    if model.settings.clickAction == .dropDown {
                        Text("Clicking Barback opens the drop-down panel, so the shortcut opens it too. Change this in Settings › Panel.")
                    }
                    if let error = model.hotkeyError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .settingsFooter()
            }

            Section {
                Label {
                    Text("Hold ⌘ and drag icons left of the │ separator to hide them.")
                } icon: {
                    Image(systemName: "hand.point.up.left")
                }
                if model.settings.alwaysHiddenEnabled {
                    Label {
                        Text("Drag icons left of the ┊ separator to keep them hidden until you Option-click Barback.")
                    } icon: {
                        Image(systemName: "eye.slash")
                    }
                }
                if let warning = model.layoutWarning {
                    Label {
                        Text(warning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                }
            } header: {
                Text("How to Use")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginItem.refresh() }
    }

    private var hidingFooter: String {
        var text = model.settings.autoRehideSeconds == 0
            ? String(localized: "Hidden items stay visible until you click Barback again.")
            : String(localized: "Items stay visible while the pointer is in the menu bar or a menu is open.")
        if model.settings.showOnHover {
            text += " " + String(localized: "Items shown by hovering hide again when the pointer leaves the menu bar.")
        }
        if model.settings.rehideOnAppSwitch {
            text += " " + String(localized: "Switching to another app hides them right away.")
        }
        return text
    }

    static func rehideLabel(_ seconds: Int) -> String {
        if seconds <= 0 { return String(localized: "Never") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds % 60 == 0 ? [.minute] : [.minute, .second]
        let text = formatter.string(from: TimeInterval(seconds)) ?? BarbackSettings.describeRehide(seconds: seconds)
        return String(localized: "After \(text)")
    }
}

// MARK: - Shortcut recorder

/// Holds the key-down monitor while recording (a class, so the SwiftUI view stays a plain struct).
@MainActor
final class HotkeyRecorderController: ObservableObject {
    private var monitor: Any?

    var isActive: Bool { monitor != nil }

    func start(onKey: @escaping (NSEvent) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKey(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Standard push button that captures the next key combination. Fully keyboard/VoiceOver operable.
struct HotkeyRecorder: View {
    @Binding var combo: KeyCombo?
    @Binding var isRecording: Bool
    @StateObject private var recorder = HotkeyRecorderController()

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? String(localized: "Type Shortcut…") : (combo?.displayString ?? String(localized: "Record Shortcut")))
                    .monospacedDigit()
                    .frame(minWidth: 110)
            }
            .barbackButton()
            .accessibilityLabel(Text("Keyboard shortcut"))
            .accessibilityValue(Text(isRecording ? String(localized: "Recording") : (combo?.accessibilityDescription ?? String(localized: "None"))))
            .accessibilityHint(Text("Activate, then press a key combination."))
            .help(isRecording ? Text("Press a key combination, or Escape to cancel") : Text("Click to record a new shortcut"))

            if combo != nil, !isRecording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Remove shortcut"))
                .help(Text("Remove shortcut"))
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        guard !recorder.isActive else { return }
        isRecording = true
        recorder.start { event in
            let modifiers = HotkeyModifiers(cocoaFlags: event.modifierFlags.rawValue)
            let code = UInt32(event.keyCode)
            if modifiers.isEmpty, code == KeyCodes.escape {
                stop()
            } else if modifiers.isEmpty, code == KeyCodes.delete || code == KeyCodes.forwardDelete {
                combo = nil
                stop()
            } else {
                let candidate = KeyCombo(keyCode: code, modifiers: modifiers)
                if candidate.isValidGlobalHotkey {
                    combo = candidate
                    stop()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    private func stop() {
        recorder.stop()
        if isRecording { isRecording = false }
    }
}

// MARK: - Items

struct ItemsSettingsView: View {
    @ObservedObject var items: ItemsModel
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Hold ⌘ and drag icons left of the │ separator to hide them.")
                } icon: {
                    Image(systemName: "hand.point.up.left")
                }
            }

            if items.hasNotch {
                Section {
                    if items.notchRows.isEmpty {
                        Label("No items are under the camera housing.", systemImage: "checkmark.circle")
                    } else {
                        ForEach(items.notchRows) { row in
                            Label(row.title, systemImage: "exclamationmark.triangle")
                        }
                    }
                } header: {
                    Text("Camera Housing")
                } footer: {
                    Text("Items under the camera housing can’t be seen. Hide some items to make room.")
                        .settingsFooter()
                }
            }

            Section {
                if items.rows.isEmpty {
                    Text(items.isRefreshing ? String(localized: "Scanning…") : String(localized: "No menu bar items found."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items.rows) { row in
                        ItemRowView(row: row)
                    }
                }
            } header: {
                HStack {
                    Text("Menu Bar Items")
                    Spacer()
                    Button {
                        items.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .barbackButton()
                    .controlSize(.small)
                    .disabled(items.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
                    .help(Text("Scan the menu bar again (⌘R)"))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Listed right to left. This list updates only when you click Refresh.")
                    if items.systemHosted, !items.accessibilityTrusted {
                        Text("macOS hosts many menu bar items in Control Center, so their app names aren’t available. Allow Accessibility access to show app names.")
                        Button("Allow Accessibility Access…") { items.requestAccessibility() }
                            .barbackButton()
                    }
                }
                .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsMetrics.width, height: 460)
        .onAppear { items.refresh() }
    }
}

private struct ItemRowView: View {
    let row: MenuBarItemRow

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if row.overlapsNotch {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help(Text("Under the camera housing"))
                        .accessibilityLabel(Text("Under the camera housing"))
                }
                Text(sectionText)
                    .foregroundStyle(.secondary)
                    .help(sectionHelp ?? "")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var sectionText: String {
        if row.barbackRole != nil { return String(localized: "Barback") }
        // The window exists inside the menu bar but isn't drawn: not something Barback hid.
        if row.visibility == .notDrawn { return String(localized: "Not Shown") }
        let section: String
        switch row.section {
        case .visible: section = String(localized: "Visible")
        case .hidden: section = String(localized: "Hidden")
        case .alwaysHidden: section = String(localized: "Always Hidden")
        case .unknown: return row.isShown ? String(localized: "Shown") : String(localized: "Off-screen")
        }
        if row.section != .visible, row.isShown { return String(localized: "\(section) · Showing") }
        if row.section == .visible, !row.isShown { return String(localized: "Off-screen") }
        return section
    }

    private var sectionHelp: String? {
        switch row.visibility {
        case .notDrawn:
            return String(localized: "macOS isn’t drawing this item. It may be turned off in System Settings › Menu Bar, or its app has hidden it.")
        case .offScreen where row.section == .visible || row.section == .unknown:
            return String(localized: "This item doesn’t fit in the menu bar.")
        default:
            return nil
        }
    }

    private var detailText: String {
        // Plain digits: PIDs and coordinates are identifiers, not quantities, so no grouping separators.
        let x = String(Int(row.item.frame.minX.rounded()))
        let pid = String(row.item.ownerPID)
        if row.item.isHostedBySystem, row.item.resolvedName == nil, row.barbackRole == nil {
            return String(localized: "Hosted by \(row.item.ownerName) · PID \(pid) · x \(x)")
        }
        return String(localized: "\(row.item.ownerName) · PID \(pid) · x \(x)")
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(verbatim: BarbackInfo.name)
                .font(.title.weight(.semibold))
            Text(versionText)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("A fast, lightweight way to tidy your menu bar.")
                .multilineTextAlignment(.center)
            Button {
                openURL(BarbackInfo.repositoryURL)
            } label: {
                Label("View on GitHub", systemImage: "arrow.up.right.square")
            }
            .barbackProminentButton()
            .padding(.top, 6)
            .help(Text(verbatim: BarbackInfo.repositoryURL.absoluteString))
            Text(verbatim: BarbackInfo.copyright)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(width: SettingsMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var versionText: String {
        if let build = model.build, build != model.version {
            return String(localized: "Version \(model.version) (\(build))")
        }
        return String(localized: "Version \(model.version)")
    }
}

// MARK: - Helpers

extension View {
    func settingsFooter() -> some View {
        self.font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
