import AppKit
import BarbackCore
import SwiftUI

struct NotchOverflowSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var items: ItemsModel

    var body: some View {
        if let controller = items.statusBar?.notchOverflow {
            NotchOverflowSettingsContent(model: model, items: items, controller: controller)
        }
    }
}

private struct NotchOverflowSettingsContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var items: ItemsModel
    @ObservedObject var controller: NotchOverflowController

    var body: some View {
        if controller.hasNotchedDisplay {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Notch access", systemImage: "macbook")
                        .font(.headline)
                    Spacer()
                    if let warning = controller.warning {
                        Label("Items don’t fit", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .help(warning)
                            .accessibilityLabel(warning)
                    }
                }
                if let warning = controller.warning {
                    Text(warning)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else if items.lastRefreshed == nil || items.snapshotContextIsStale {
                    Text("Reveal items and refresh the Items snapshot to measure what fits beside the notch. No background scan is used for this warning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Fit counts describe observed, drawn items only. Missing or not-drawn items cannot be attributed to the notch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Enable notch overflow bar", isOn: Binding(
                    get: { model.settings.notchOverflowEnabled },
                    set: { controller.setEnabled($0) }
                ))
                .help("Accessibility-only access to identified items on a notched display. Off by default.")
                Text("Uses application icons and Accessibility to open safely identified items. Never requests Screen Recording. Unidentified or unavailable items stay unavailable; Barback cannot make macOS expose them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let explanation = controller.explanation {
                    Label(explanation, systemImage: "info.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(explanation)
                }
                if model.settings.notchOverflowEnabled {
                    Button(controller.isShown ? "Close Notch Bar" : "Open Notch Bar") {
                        if controller.isShown { controller.close() } else { controller.show() }
                    }
                }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Notch access")
        }
    }
}
