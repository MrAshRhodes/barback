import AppKit
import BarbackCore
import Testing
@testable import Barback

@Suite("Notch overflow integration", .serialized)
@MainActor
struct NotchOverflowTests {
    private func row(
        _ id: UInt32, owner: String = "Sample", display: Int? = 0,
        section: MenuBarSection = .hidden, visibility: ItemVisibility = .shown,
        detail: String? = nil, identified: Bool = true, role: String? = nil
    ) -> MenuBarItemRow {
        MenuBarItemRow(
            item: MenuBarItem(
                windowID: id, ownerName: owner, ownerPID: 12_345,
                frame: CGRect(x: 700, y: 0, width: 24, height: 24),
                isOnScreen: visibility == .shown, bundleID: identified ? "test.\(owner)" : nil,
                detail: detail
            ),
            section: section, visibility: visibility, overlapsNotch: true,
            barbackRole: role, key: ItemKey(owner: "unsafe-positional-key", detail: "#\(id)"), display: display
        )
    }

    @Test func safeCandidatesKeepTheRequestedMirroredCopy() {
        let rows = [row(1, display: 0), row(2, display: 1)]
        let result = NotchOverflowContent.candidates(rows: rows, display: 1, alwaysHiddenEnabled: false)
        #expect(result.map(\.id) == [2])
        #expect(result.first?.display == 1)
        #expect(result.first?.key == ItemKey(owner: "test.Sample"))
    }

    @Test func ambiguousUnidentifiedUnavailableAndOwnItemsNeverBecomeActions() {
        let rows = [
            row(1), row(2), row(3, owner: "Unidentified", identified: false),
            row(4, owner: "Unavailable", visibility: .notDrawn),
            row(5, owner: "Barback", role: "Barback"),
            row(6, owner: "External", display: 1),
            row(7, owner: "Always", section: .alwaysHidden),
            row(8, owner: "Safe"),
        ]
        let result = NotchOverflowContent.candidates(rows: rows, display: 0, alwaysHiddenEnabled: false)
        #expect(result.map(\.id) == [8])
        #expect(result.first?.key.owner == "test.Safe")
        #expect(NotchOverflowContent.candidates(rows: rows, display: 0, alwaysHiddenEnabled: true).map(\.id).sorted() == [7, 8])
    }

    @Test func observationsDoNotTurnOffScreenItemsIntoPermissionFreeOpenings() {
        let rows = [row(1, visibility: .offScreen)]
        let result = NotchOverflowContent.candidates(rows: rows, display: 0, alwaysHiddenEnabled: false)
        #expect(result.count == 1)
        #expect(result.first?.revealAction == .show)
    }

    @Test func preciseWarningsRequireFreshSuccessfulSnapshot() {
        let display = MenuBarDisplay(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notch: CGRect(x: 656, y: 0, width: 200, height: 32)
        )
        for stale in [false, true] {
            let items = ItemsModel(
                snapshot: [row(1)], displays: [display], displayNames: ["Built-in"],
                capturedAt: Date(), isStale: stale
            )
            let result = NotchOverflowContent.fit(items: items, state: .shown)
            #expect(result.isEmpty == stale)
            let warning = NotchOverflowContent.warning(results: result, names: items.snapshotDisplayNames)
            #expect((warning == nil) == stale)
            if !stale {
                #expect(warning?.contains("1") == true)
                #expect(warning?.contains("Built-in") == true)
            }
        }
        let failed = ItemsModel(snapshot: [row(1)], displays: [display], capturedAt: Date(), scanError: "Unavailable")
        #expect(NotchOverflowContent.fit(items: failed, state: .shown).isEmpty)
    }

    @Test func disabledAndExternalOnlyPathsDoNotPromptOrScan() throws {
        _ = NSApplication.shared
        let suite = "BarbackTests.Notch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for enabled in [false, true] {
            let model = AppModel(store: SettingsStore(defaults: defaults))
            model.settings.notchOverflowEnabled = enabled
            let items = ItemsModel(snapshot: [])
            var trustedChecks = 0
            var prompts = 0
            var scans = 0
            let controller = NotchOverflowController(
                model: model, items: items,
                isTrusted: { trustedChecks += 1; return false },
                requestTrust: { prompts += 1; return false },
                hasNotch: { !enabled }, refresh: { scans += 1 }
            )
            controller.sectionState = { .shown }
            controller.settingsDidChange()
            controller.sectionDidChange()
            controller.show()
            controller.close()
            #expect(prompts == 0)
            #expect(scans == 0)
            #expect(trustedChecks == 0)
            #expect(!controller.isShown && !controller.isInteracting)
        }
    }

    @Test func deniedEnableRevertsWithoutScanningAndExplainsRecovery() throws {
        _ = NSApplication.shared
        let suite = "BarbackTests.Notch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: SettingsStore(defaults: defaults))
        let items = ItemsModel(snapshot: [], accessibilityTrusted: false)
        var prompts = 0
        var scans = 0
        let controller = NotchOverflowController(
            model: model, items: items, isTrusted: { false },
            requestTrust: { prompts += 1; return false },
            hasNotch: { true }, refresh: { scans += 1 }
        )
        controller.setEnabled(true)
        #expect(!model.settings.notchOverflowEnabled)
        #expect(prompts == 1 && scans == 0)
        #expect(controller.explanation?.contains("Accessibility") == true)
        #expect(!controller.isInteracting)
        controller.setEnabled(false)
        #expect(prompts == 1 && scans == 0)
    }

    @Test func restoredPreferenceCannotRequestPermission() throws {
        _ = NSApplication.shared
        let suite = "BarbackTests.Notch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: SettingsStore(defaults: defaults))
        model.settings.notchOverflowEnabled = true
        var prompts = 0
        let controller = NotchOverflowController(
            model: model, items: ItemsModel(snapshot: []), isTrusted: { false },
            requestTrust: { prompts += 1; return true }, hasNotch: { true }
        )
        controller.settingsDidChange()
        #expect(!model.settings.notchOverflowEnabled)
        #expect(prompts == 0)
        #expect(controller.explanation != nil)
    }

    @Test func automaticRehideWaitsForBarButExplicitHideStillWorks() {
        #expect(StatusBarController.shouldDeferAutomaticRehide(
            nextState: .hidden, userInitiated: false, itemOpening: false, barInteracting: true
        ))
        #expect(!StatusBarController.shouldDeferAutomaticRehide(
            nextState: .hidden, userInitiated: true, itemOpening: false, barInteracting: true
        ))
        #expect(!StatusBarController.shouldDeferAutomaticRehide(
            nextState: .shown, userInitiated: false, itemOpening: false, barInteracting: true
        ))
    }

    @Test func nativeStripHasPagingControlsAndKeyboardEscape() throws {
        _ = NSApplication.shared
        let panel = NotchOverflowWindow(reduceMotion: { true })
        defer { panel.close() }
        panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 360, height: 240), display: false)
        let rows = (1...10).map { row(UInt32($0), owner: "App\($0)") }
        panel.update(
            items: NotchOverflowContent.candidates(rows: rows, display: 0, alwaysHiddenEnabled: false),
            title: "Test display", status: "Application icons", canOpen: true, refreshing: false
        )
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(panel.displayedTitles.count == 10)
        #expect(panel.canPageNext)
        #expect(!panel.canPagePrevious)
        let next = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 121
        ))
        #expect(panel.handlePagingKey(next))
        // Reduce Motion makes keyboard paging immediate rather than waiting for an animation.
        #expect(panel.horizontalOffset > 0)
        #expect(panel.canPagePrevious)
        var closed = false
        panel.onClose = { closed = true }
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 53
        ))
        #expect(panel.handlePagingKey(escape))
        #expect(closed)
    }

    @Test func nativeStripDisablesItemActionsUntilTheSnapshotIsSafe() throws {
        _ = NSApplication.shared
        let panel = NotchOverflowWindow(reduceMotion: { true })
        defer { panel.close() }
        panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 360, height: 240), display: false)
        let candidates = NotchOverflowContent.candidates(rows: [row(1, owner: "Safe")], display: 0, alwaysHiddenEnabled: false)
        var opened = 0
        panel.onOpen = { _ in opened += 1 }
        panel.update(items: candidates, title: "Test", status: "Stale", canOpen: false, refreshing: false)
        func buttons(_ view: NSView) -> [NSButton] {
            if let button = view as? NSButton { return [button] }
            return view.subviews.flatMap(buttons)
        }
        let itemButton = try #require(panel.contentView.flatMap { buttons($0).first { $0.title == "Safe" } })
        #expect(!itemButton.isEnabled)
        itemButton.performClick(nil)
        #expect(opened == 0)
        panel.update(items: candidates, title: "Test", status: "Ready", canOpen: true, refreshing: false)
        #expect(itemButton.isEnabled)
        itemButton.performClick(nil)
        #expect(opened == 1)
    }
}
