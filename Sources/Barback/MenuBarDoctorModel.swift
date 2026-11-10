import AppKit
import BarbackCore

/// Owned by AppModel so closing a diagnostic sheet does not discard its bounded, session-only evidence.
@MainActor
final class MenuBarDoctorModel: ObservableObject {
    @Published var selectedKey: ItemKey?
    @Published private(set) var history = MenuBarDoctorHistory()
    @Published private(set) var snapshot: MenuBarDoctor.Snapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var isOpeningApp = false
    @Published private(set) var actionMessage: String?
    @Published private(set) var actionFailed = false

    func targets(settings: BarbackSettings) -> [MenuBarDoctor.Target] {
        MenuBarDoctor.targets(
            snapshot: snapshot, savedKeys: settings.groups.flatMap(\.itemKeys) + settings.itemHotkeys.map(\.key),
            history: history, now: Date()
        )
    }

    var report: MenuBarDoctor.Report? {
        selectedKey.map { MenuBarDoctor.report(for: $0, snapshot: snapshot, history: history, now: Date()) }
    }

    func begin(items: ItemsModel, settings: BarbackSettings) {
        guard !isScanning else { return }
        // An Items snapshot can seed a previous observation, but its old section state is not known.
        if let date = items.lastRefreshed, snapshot?.scannedAt != date {
            let previous = capture(items: items, attemptedAt: date, sectionState: nil, forceStale: true)
            // Items preserves the last successful rows and timestamp when a later collection fails.
            var successfulRows = previous
            successfulRows.failure = nil
            history.record(successfulRows, now: Date())
            snapshot = previous
        }
        selectDefault(settings: settings)
        rescan(items: items, settings: settings)
    }

    func rescan(items: ItemsModel, settings: BarbackSettings) {
        guard !isScanning, !isOpeningApp else { return }
        isScanning = true
        actionMessage = nil
        invalidateContext()
        let startedAt = Date()
        let previousDate = items.lastRefreshed
        let sectionState = items.statusBar?.state
        items.refresh { [weak self, weak items] in
            guard let self, let items else { return }
            let unchangedState = items.statusBar?.state == sectionState ? sectionState : nil
            var result = self.capture(items: items, attemptedAt: startedAt, sectionState: unchangedState)
            if result.failure == nil && (result.scannedAt == nil || result.scannedAt == previousDate) {
                result.failure = "No new snapshot was collected. The previous observation is not an absence check."
            }
            self.history.record(result, now: Date())
            self.snapshot = result
            self.isScanning = false
            self.selectDefault(settings: settings)
        }
    }

    func invalidateContext() {
        guard var snapshot, !snapshot.contextIsStale else { return }
        snapshot.contextIsStale = true
        self.snapshot = snapshot
    }

    func clearActionMessage() {
        actionMessage = nil
        actionFailed = false
    }

    func reveal(items: ItemsModel, alwaysHiddenEnabled: Bool) {
        guard !isScanning, !isOpeningApp else { return }
        guard let statusBar = items.statusBar else {
            setAction("Barback's section controller is unavailable. Nothing was changed.", failed: true)
            return
        }
        let section = report?.current?.entry.section ?? report?.previous?.entry.section
        let revealAll = section == .alwaysHidden && alwaysHiddenEnabled
        statusBar.perform(revealAll ? .showAll : .show, userInitiated: true, announce: true)
        invalidateContext()
        let revealed = revealAll ? statusBar.state == .shownAll : statusBar.state.isRevealed
        if revealed {
            setAction(
                "Barback requested \(revealAll ? "all sections" : "the hidden section") to be revealed. "
                    + "Rescan to check the item; macOS may still not draw it. Your auto-rehide settings still apply."
            )
        } else {
            setAction("Barback could not confirm the section reveal. No item was opened. Try the menu-bar toggle, then rescan.", failed: true)
        }
    }

    func openSourceApp() {
        guard !isScanning, !isOpeningApp else { return }
        guard let bundleID = report?.sourceBundleID else {
            setAction("The originating app is not reliably identified. A hosting process will not be opened.", failed: true)
            return
        }
        guard !MenuBarItemParser.systemHostBundleIDs.contains(bundleID.lowercased()),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              Bundle(url: url)?.bundleIdentifier == bundleID else {
            setAction("The identified app (\(bundleID)) could not be located or verified. Nothing was launched.", failed: true)
            return
        }
        isOpeningApp = true
        actionMessage = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                self.isOpeningApp = false
                if let error {
                    self.setAction("The app could not be opened: \(error.localizedDescription)", failed: true)
                } else if app?.bundleIdentifier != bundleID {
                    self.setAction("The app-opening request did not confirm the expected app. Rescan before trying again.", failed: true)
                } else {
                    self.invalidateContext()
                    self.setAction("Opened the identified app. This does not guarantee its menu-bar item exists. Check its menu-bar preference, then rescan.")
                }
            }
        }
    }

    private func selectDefault(settings: BarbackSettings) {
        let available = targets(settings: settings)
        if selectedKey == nil || !available.contains(where: { $0.key == selectedKey }) {
            selectedKey = available.first?.key
        }
    }

    private func capture(
        items: ItemsModel, attemptedAt: Date, sectionState: SectionState?, forceStale: Bool = false
    ) -> MenuBarDoctor.Snapshot {
        MenuBarDoctor.Snapshot(
            entries: items.rows.filter { $0.barbackRole == nil }.map {
                MenuBarDoctor.Entry(item: $0.item, section: $0.section, visibility: $0.visibility, display: $0.display)
            },
            displays: items.snapshotDisplays, displayNames: items.snapshotDisplayNames,
            scannedAt: items.lastRefreshed, attemptedAt: attemptedAt, failure: items.scanError,
            accessibilityTrusted: items.accessibilityTrusted,
            contextIsStale: forceStale || items.snapshotContextIsStale,
            sectionState: sectionState, frontmostApp: items.snapshotFrontmostApp,
            runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        )
    }

    private func setAction(_ message: String, failed: Bool = false) {
        actionFailed = failed
        actionMessage = message
    }
}
