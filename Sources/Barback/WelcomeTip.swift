import AppKit
import BarbackCore
import SwiftUI

/// The getting-started popover shown under the chevron on first launch (and from the menu).
@MainActor
enum WelcomeTip {
    static func makeController(hotkey: KeyCombo?, onDone: @escaping () -> Void) -> NSViewController {
        let host = NSHostingController(rootView: WelcomeTipView(hotkey: hotkey, onDone: onDone))
        host.sizingOptions = [.preferredContentSize]
        return host
    }
}

struct WelcomeTipView: View {
    let hotkey: KeyCombo?
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Barback Is Ready")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            tip("hand.point.up.left", "Hold ⌘ and drag icons to the left of the │ separator to hide them.")
            tip("cursorarrow.click", "Click the chevron to show or hide them. Right-click it for more options.")
            if let hotkey {
                tip("keyboard", "Press \(hotkey.displayString) to show or hide them from anywhere.")
            }
            tip("paintbrush", "Choose a different icon and separators in Settings › Appearance.")
            HStack {
                Spacer()
                Button("Got It", action: onDone)
                    .barbackProminentButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func tip(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
        }
    }
}
