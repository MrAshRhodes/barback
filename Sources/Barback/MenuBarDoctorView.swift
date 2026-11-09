import SwiftUI
import BarbackCore

@MainActor
struct MenuBarDoctorView: View {
    @ObservedObject var items: ItemsModel
    @ObservedObject var model: AppModel
    @ObservedObject private var doctor: MenuBarDoctorModel
    @Environment(\.dismiss) private var dismiss

    init(items: ItemsModel, model: AppModel) {
        self.items = items
        self.model = model
        doctor = model.menuBarDoctor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    targetPicker
                    if doctor.isScanning {
                        ProgressView("Collecting a requested snapshot…")
                            .accessibilityLabel("Menu Bar Doctor scan in progress")
                    }
                    collectionEvidence
                    if let report = doctor.report {
                        itemEvidence(report)
                        safeActions(report)
                    } else {
                        Text("No reliably identified or saved items are available yet. Rescan, or check the app's own menu-bar setting. Unidentified hosting processes are not used as item identities.")
                            .foregroundStyle(.secondary)
                    }
                    guidance
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                Text("On demand · local to this session · no new permissions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 580, idealHeight: 720)
        .onAppear {
            doctor.begin(items: items, settings: model.settings)
        }
        .onChange(of: doctor.selectedKey) { _, _ in doctor.clearActionMessage() }
        .onChange(of: items.snapshotContextIsStale) { _, stale in
            if stale { doctor.invalidateContext() }
        }
        .onChange(of: items.lastRefreshed) { _, date in
            if !doctor.isScanning, date != doctor.snapshot?.scannedAt { doctor.invalidateContext() }
        }
        .onChange(of: items.accessibilityTrusted) { _, _ in doctor.invalidateContext() }
        .task(id: doctor.snapshot?.scannedAt) {
            guard let scannedAt = doctor.snapshot?.scannedAt,
                  MenuBarDoctor.status(of: doctor.snapshot, now: Date()) == .current else { return }
            // A single expiry updates stale labels; this never polls or collects another snapshot.
            let remaining = scannedAt.addingTimeInterval(MenuBarDoctor.currentEvidenceLifetime).timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            guard !Task.isCancelled else { return }
            doctor.invalidateContext()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "stethoscope")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Menu Bar Doctor").font(.title2.weight(.semibold))
                Text("Find a missing item. Inspect evidence, not a diagnosis.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                doctor.rescan(items: items, settings: model.settings)
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel("Rescan menu-bar items")
            .help("Collect one new menu-bar snapshot without requesting additional permissions.")
            .disabled(doctor.isScanning || doctor.isOpeningApp)
        }
        .padding(24)
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Item to investigate", selection: $doctor.selectedKey) {
                Text("Choose an item").tag(Optional<ItemKey>.none)
                ForEach(doctor.targets(settings: model.settings)) { target in
                    Text(target.title + (target.isSaved ? " · saved" : target.wasPreviouslyObserved ? " · seen this session" : ""))
                        .tag(Optional(target.key))
                }
            }
            .accessibilityLabel("Known, saved, or previously observed menu-bar item")
            .disabled(doctor.isOpeningApp)
            if let key = doctor.selectedKey {
                Text(key.owner + (key.detail.map { " · \($0)" } ?? ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var collectionEvidence: some View {
        evidenceCard("Collection", symbol: "clock") {
            if let snapshot = doctor.snapshot {
                evidenceRow("Requested", date(snapshot.attemptedAt))
                evidenceRow("Last successful scan", snapshot.scannedAt.map(date) ?? "No successful scan")
                evidenceRow("Evidence state", evidenceState)
                evidenceRow("Accessibility", snapshot.accessibilityTrusted ? "Allowed for this scan" : "Not allowed — identification may be incomplete")
                evidenceRow("Displays captured", snapshot.displayNames.isEmpty ? "Unknown" : snapshot.displayNames.joined(separator: ", "))
                evidenceRow("Frontmost app at scan", snapshot.frontmostApp ?? "Unknown")
                if let failure = snapshot.failure {
                    Label("Collection failed: \(failure)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } else {
                Text("No scan has completed. No absence check is available.")
            }
            Text("Window snapshots can omit items. A successful scan is not a complete inventory. No Screen Recording permission is requested, and window names can be unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func itemEvidence(_ report: MenuBarDoctor.Report) -> some View {
        evidenceCard("Selected item", symbol: "viewfinder") {
            evidenceRow("Observation", presence(report))
            evidenceRow("Last observed", report.lastObservedAt.map(date) ?? "Unknown — no reliable observation retained")
            evidenceRow("Identity confidence", confidence(report.confidence))
            evidenceRow("Unidentified windows", "\(report.unidentifiedCount) in the captured snapshot")
            if let observation = report.current ?? report.previous {
                let previous = report.current == nil
                if previous {
                    Label("Previous observation only — not the item's current location or state", systemImage: "clock.arrow.circlepath")
                        .font(.callout.weight(.medium))
                }
                evidenceRow(previous ? "Previous display" : "Observed display", displayDescription(observation))
                evidenceRow(previous ? "Previous Barback state" : "Barback state at scan", hiddenState(observation.hiddenState))
                evidenceRow("Window at observation", visibility(observation.entry.visibility))
                evidenceRow("Notch geometry", notch(observation.geometry.notch))
                evidenceRow("Captured-item overlap", overlap(observation.geometry.overlapsCapturedPeer))
            } else {
                evidenceRow("Barback-hidden state", "Unknown — no reliable item location")
                evidenceRow("Geometry", "Unknown — no reliable item frame and display")
            }
            if let bundle = report.sourceBundleID {
                evidenceRow("Identified app", bundle)
                evidenceRow("App at requested check", report.sourceAppRunning == true ? "Running" : "Not observed running")
                Text("The app identity comes from a reliable item observation. App/process state does not establish whether its icon exists or is visible.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                evidenceRow("Source app", "Unknown or system-hosted — no app-running claim")
                Text("Control Center and SystemUIServer are hosts, not evidence of an originating app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Spatial overlap is only a clue, not proof of why an item disappeared. Application-menu width and macOS visibility policy are not fully measured here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func safeActions(_ report: MenuBarDoctor.Report) -> some View {
        evidenceCard("Safe next steps", symbol: "hand.point.up.left") {
            HStack {
                Button(revealTitle(report)) {
                    doctor.reveal(items: items, alwaysHiddenEnabled: model.settings.alwaysHiddenEnabled)
                }
                .accessibilityLabel("Reveal Barback's own section without opening or moving the selected item")
                .disabled(items.statusBar == nil || doctor.isScanning || doctor.isOpeningApp)
                Button("Open identified app") { doctor.openSourceApp() }
                    .accessibilityLabel("Open the reliably identified source application")
                    .disabled(report.sourceBundleID == nil || doctor.isScanning || doctor.isOpeningApp)
            }
            if items.statusBar == nil {
                Text("Reveal is unavailable because Barback's section controller is not connected.").font(.caption)
            }
            if report.sourceBundleID == nil {
                Text("Open app is unavailable: a reliable, non-system-host app identity is required.").font(.caption)
            }
            if doctor.isOpeningApp { ProgressView("Opening the identified app…") }
            if let message = doctor.actionMessage {
                Label(message, systemImage: doctor.actionFailed ? "exclamationmark.triangle" : "info.circle")
                    .foregroundStyle(doctor.actionFailed ? Color.orange : Color.secondary)
                    .accessibilityLabel((doctor.actionFailed ? "Action failed. " : "") + message)
            }
        }
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What this cannot tell you").font(.headline)
            Text("Not observed never means deleted. Check the app's own “show in menu bar” setting and System Settings → Control Center / Menu Bar (the name varies by macOS version). After changing the frontmost app, display arrangement, or Barback section, rescan.")
            Text("No automatic repair, app launch, rearrangement, permission reset, or system-process restart. Previous evidence keeps at most 256 item identities for 30 days in memory and disappears when Barback quits.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func evidenceCard<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func evidenceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).foregroundStyle(.secondary).frame(width: 156, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var evidenceState: String {
        if doctor.isScanning { return "New scan pending — earlier evidence is not a current check" }
        switch MenuBarDoctor.status(of: doctor.snapshot, now: Date()) {
        case .current: return "Recent requested snapshot, not live monitoring"
        case .stale: return "Stale — age or context changed; rescan before relying on it"
        case .failed: return "Failed — previous rows are not a successful absence check"
        case .notScanned: return "Unknown — no successful snapshot"
        }
    }

    private func presence(_ report: MenuBarDoctor.Report) -> String {
        if doctor.isScanning { return "Checking — earlier observations only" }
        switch report.status {
        case .failed: return "Unknown — the requested scan failed"
        case .stale: return "Unknown now — the available snapshot is stale"
        case .notScanned: return "Unknown — no successful scan"
        case .current:
            switch report.presence {
            case .observed: return "Observed in this scan (not necessarily drawn)"
            case .notObserved: return "Not observed in this scan — not proof of deletion"
            case .ambiguous: return "Ambiguous identity — cannot safely match an item"
            case .unknown: return "Unknown"
            }
        }
    }

    private func confidence(_ value: MenuBarDoctor.Confidence) -> String {
        switch value {
        case .identified: return "Reliable selector for this observation; cause unknown"
        case .limited: return "Limited — permissions, missing identities, or no matched item"
        case .unknown: return "Unknown for a current observation"
        }
    }

    private func displayDescription(_ observation: MenuBarDoctor.Observation) -> String {
        guard let frame = observation.display?.frame,
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
              frame.width < CGFloat(Int.max), frame.height < CGFloat(Int.max) else {
            return "Unknown — display geometry unavailable"
        }
        let name = observation.displayName ?? observation.entry.display.map { "Display \($0 + 1) in this snapshot" } ?? "Captured display"
        return "\(name) · \(Int(frame.width)) × \(Int(frame.height)) pt"
    }

    private func hiddenState(_ value: MenuBarDoctor.HiddenState) -> String {
        switch value {
        case .hiddenSectionCollapsed: return "In Barback's hidden section; section was collapsed"
        case .alwaysHiddenSectionCollapsed: return "In Barback's always-hidden section; section was collapsed"
        case .sectionRevealed: return "Item's Barback section was revealed"
        case .notManaged: return "In the visible section, outside Barback's hidden sections"
        case .unknown: return "Unknown — section or reveal state could not be verified"
        }
    }

    private func visibility(_ value: ItemVisibility) -> String {
        switch value {
        case .shown: return "Reported on screen"
        case .offScreen: return "Outside the captured display"
        case .notDrawn: return "Window observed, but not reported drawn by macOS"
        }
    }

    private func notch(_ value: MenuBarDoctor.NotchClue) -> String {
        switch value {
        case .geometryUnavailable: return "Unavailable or unusable — no notch conclusion"
        case .noNotch: return "No notch in this captured display's geometry"
        case .clearOfNotch: return "Captured item frame does not overlap the measured notch"
        case .overlapsNotch: return "Captured item frame overlaps the measured notch — a clue only"
        case .outsideDisplay: return "Item was off-screen or undrawn — no visible-notch conclusion"
        }
    }

    private func overlap(_ value: Bool?) -> String {
        guard let value else { return "Unknown — visible peer geometry unavailable" }
        return value ? "Measured overlap with another captured item — a clue only" : "No overlap with captured peers; overall crowding is still unknown"
    }

    private func revealTitle(_ report: MenuBarDoctor.Report) -> String {
        let section = report.current?.entry.section ?? report.previous?.entry.section
        return section == .alwaysHidden && model.settings.alwaysHiddenEnabled ? "Reveal all Barback sections" : "Reveal Barback's hidden section"
    }

    private func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .standard)
    }
}
