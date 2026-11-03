import CoreGraphics
import Foundation
import Testing
@testable import BarbackCore

@Suite("Stable system-item identification")
struct SystemItemIdentityTests {
    let cgFrame = CGRect(x: -3690, y: 0, width: 38, height: 33)
    let axFrame = CGRect(x: -3682, y: 5.5, width: 22, height: 22)

    @Test(arguments: [
        ("wifi", "Wi-Fi"), ("bluetooth", "Bluetooth"), ("battery", "Battery"),
        ("sound", "Sound"), ("focusmode", "Focus"), ("now-playing", "Now Playing"),
        ("clock", "Clock"), ("controlcenter", "Control Center"), ("display", "Display"),
    ])
    func knownIdentifiersHaveCompatibleCanonicalDetails(suffix: String, label: String) {
        for host in MenuBarItemParser.systemHostBundleIDs {
            for description in ["\(label), connected, 3 bars", "localized state", "", label] {
                let item = AccessibilityItem(
                    appName: "Control Centre", bundleID: host, pid: 50, description: description,
                    identifier: "com.apple.menuextra.\(suffix)", frame: axFrame
                )
                #expect(item.detail == label)
            }
        }
    }

    @Test(arguments: [nil, "", "com.apple.menuextra.unknown", "session-dependent-id"])
    func descriptionsWithoutKnownIdentifiersAreNotSelectors(identifier: String?) {
        let windows = [window()]
        let candidate = AccessibilityItem(
            appName: "Control Centre", bundleID: "com.apple.controlcenter", pid: 50,
            description: "Sound", identifier: identifier, frame: axFrame
        )
        #expect(candidate.detail == nil, "Even a canonical English description is not stable across locales")
        let resolved = MenuBarItemParser.resolve(windows, using: [candidate])
        #expect(resolved[0].resolvedName == nil)
        #expect(resolved[0].detail == nil)
        #expect(ItemKeyAssigner.panelKeys(for: resolved).isEmpty)
    }

    @Test func windowTitlesCannotSubstituteForSystemIdentifiers() {
        var item = window()
        item.bundleID = "com.apple.controlcenter"
        item.title = "Wi-Fi"
        #expect(ItemKeyAssigner.panelKeys(for: [item]).isEmpty)
    }

    @Test func centeredSmallerIconsResolveWithBritishOwnerAndHiddenCoordinates() {
        let windows = [window()]
        let candidate = AccessibilityItem(
            appName: "Control Centre", bundleID: "com.apple.controlcenter", pid: 50,
            description: "Sound, muted", identifier: "com.apple.menuextra.sound", frame: axFrame
        )
        #expect(windows[0].isHostedBySystem)
        #expect(FrameMatcher.bestMatchIndex(for: cgFrame, among: [axFrame]) == 0)
        let resolved = MenuBarItemParser.resolve(windows, using: [candidate])
        #expect(resolved[0].panelName == "Sound")
        #expect(resolved[0].sourcePID == 50)
        #expect(ItemKeyAssigner.panelKeys(for: resolved)[1] == ItemKey(owner: "com.apple.controlcenter", detail: "Sound"))
    }

    @Test func keysSurviveStateLocaleWindowIDAndPositionChanges() {
        var keys: [ItemKey] = []
        for (index, description) in ["Wi-Fi, connected, 3 bars", "Wi-Fi, disconnected", "WLAN, verbunden", "Wi-Fi"].enumerated() {
            let x = index % 2 == 0 ? CGFloat(-3690) : CGFloat(400)
            var raw = window()
            raw.windowID = UInt32(100 + index)
            raw.frame.origin.x = x
            let candidate = AccessibilityItem(
                appName: index % 2 == 0 ? "Control Centre" : "Kontrollzentrum",
                bundleID: "com.apple.controlcenter", pid: Int32(50 + index),
                description: description, identifier: "com.apple.menuextra.wifi",
                frame: CGRect(x: x + 8, y: 5.5, width: 22, height: 22)
            )
            let resolved = MenuBarItemParser.resolve([raw], using: [candidate])
            if let key = ItemKeyAssigner.panelKeys(for: resolved)[raw.windowID] { keys.append(key) }
        }
        #expect(keys.count == 4)
        #expect(Set(keys) == [ItemKey(owner: "com.apple.controlcenter", detail: "Wi-Fi")])
        #expect(keys.first?.linkIdentifier == "com.apple.controlcenter/Wi-Fi")
        #expect(BarbackURLRequest.parse(URL(string: "barback://open?item=com.apple.controlcenter/Wi-Fi")!)
                == .success(.open(.key(ItemKey(owner: "com.apple.controlcenter", detail: "Wi-Fi")))))
    }

    @Test func invalidFramesAndDifferentRowsNeverMatch() {
        #expect(FrameMatcher.bestMatchIndex(for: cgFrame, among: [.zero, axFrame]) == 1)
        #expect(FrameMatcher.bestMatchIndex(for: cgFrame, among: [CGRect(x: -3671, y: 16.5, width: 0, height: 0)]) == nil)
        #expect(FrameMatcher.bestMatchIndex(for: cgFrame, among: [axFrame.offsetBy(dx: 0, dy: 30)]) == nil)
        #expect(FrameMatcher.bestMatchIndex(for: .zero, among: [axFrame]) == nil)
        #expect(FrameMatcher.bestMatchIndex(for: cgFrame, among: [axFrame.offsetBy(dx: 1, dy: 0)]) == 0)
        #expect(FrameMatcher.bestMatchIndex(for: cgFrame, among: [axFrame.offsetBy(dx: 3, dy: 0)]) == nil)
    }

    @Test func matchingRejectsCompetingElementsAndWindowsInEitherOrder() {
        #expect(FrameMatcher.bestMatchIndex(for: cgFrame, among: [axFrame, axFrame]) == nil)
        #expect(FrameMatcher.matchIndices(for: [cgFrame, cgFrame.offsetBy(dx: 1, dy: 0)], among: [axFrame]).isEmpty)
        #expect(FrameMatcher.matchIndices(for: [cgFrame.offsetBy(dx: 1, dy: 0), cgFrame], among: [axFrame]).isEmpty)
        let candidate = AccessibilityItem(
            appName: "Control Centre", bundleID: "com.apple.controlcenter", pid: 50,
            identifier: "com.apple.menuextra.sound", frame: axFrame
        )
        var sibling = window()
        sibling.windowID = 2
        sibling.frame = cgFrame.offsetBy(dx: 1, dy: 0)
        let resolved = MenuBarItemParser.resolve([window(), sibling], using: [candidate])
        #expect(resolved.allSatisfy { $0.bundleID == nil })
        #expect(ItemKeyAssigner.panelKeys(for: resolved).isEmpty)
    }

    @Test func emptyAccessibilityResultLeavesSystemItemsUnidentified() {
        let resolved = MenuBarItemParser.resolve([window()], using: [])
        #expect(resolved == [window()])
        #expect(ItemKeyAssigner.panelKeys(for: resolved).isEmpty)
    }

    private func window() -> MenuBarItem {
        typealias K = MenuBarItemParser.Key
        return MenuBarItemParser.parse([[
            K.number: 1, K.layer: 25, K.ownerName: "Control Centre", K.ownerPID: 50,
            K.bounds: ["X": cgFrame.minX, "Y": cgFrame.minY, "Width": cgFrame.width, "Height": cgFrame.height],
            K.isOnScreen: false,
        ]])[0]
    }
}
