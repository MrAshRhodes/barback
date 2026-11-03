import AppKit
import ApplicationServices
import BarbackCore
import Testing
@testable import Barback

@Suite("Accessibility scanner IPC")
struct AccessibilityScannerTests {
    private final class Fixture {
        let app = RunningAppInfo(pid: 50, name: "Control Centre", bundleID: "com.apple.controlcenter")
        let bar = AXUIElementCreateApplication(51)
        let child = AXUIElementCreateApplication(52)
        let zeroChild = AXUIElementCreateApplication(53)
        var time: TimeInterval = 0
        var delay: TimeInterval = 0
        var rootDelay: TimeInterval = 0
        var rootError: AXError = .success
        var failedAttribute: String?
        var timeoutError: AXError = .success
        var timeouts: [(element: AXUIElement, value: Float)] = []
        var queried: [AXUIElement] = []
        var presses: [AXUIElement] = []

        var windows: [[String: Any]] {
            typealias K = MenuBarItemParser.Key
            return [[
                K.number: 1, K.layer: 25, K.ownerName: "Control Centre", K.ownerPID: 50,
                K.bounds: ["X": -3690, "Y": 0, "Width": 38, "Height": 33],
                K.isOnScreen: false,
            ]]
        }

        var reader: AccessibilityReader {
            AccessibilityReader(
                now: { self.time },
                setTimeout: { self.timeouts.append(($0, $1)); return self.timeoutError },
                copyAttribute: { element, attribute in
                    self.queried.append(element)
                    let cost = attribute == "AXExtrasMenuBar" ? self.rootDelay : self.delay
                    let timeout = TimeInterval(self.timeouts.last!.value)
                    self.time += min(cost, timeout)
                    if cost > timeout { return (.cannotComplete, nil) }
                    if attribute == self.failedAttribute { return (.cannotComplete, nil) }
                    switch attribute {
                    case "AXExtrasMenuBar": return (self.rootError, self.rootError == .success ? self.bar : nil)
                    case kAXChildrenAttribute: return (.success, [self.child, self.zeroChild] as CFArray)
                    case kAXPositionAttribute:
                        var origin = CGPoint(x: -3682, y: 5.5)
                        return (.success, AXValueCreate(.cgPoint, &origin))
                    case kAXSizeAttribute:
                        var size = CFEqual(element, self.zeroChild) ? CGSize.zero : CGSize(width: 22, height: 22)
                        return (.success, AXValueCreate(.cgSize, &size))
                    case kAXIdentifierAttribute: return (.success, "com.apple.menuextra.sound" as CFString)
                    case kAXDescriptionAttribute: return (.success, "Sound, muted" as CFString)
                    default: return (.attributeUnsupported, nil)
                    }
                },
                press: { self.presses.append($0); return .success }
            )
        }

        func scan(trusted: Bool = true) -> MenuBarScan {
            AccessibilityScanner.scan(windows: windows, tops: [0], trusted: trusted, apps: [app], reader: reader)
        }
    }

    @Test func slowSystemHostResolvesAndTimeoutIsAppliedToEveryQueriedElement() throws {
        let fixture = Fixture()
        fixture.rootDelay = 0.2
        let scan = fixture.scan()
        #expect(scan.elements.count == 1, "Zero-size children must be discarded")
        #expect(scan.items.first?.panelName == "Sound")
        #expect(ItemKeyAssigner.panelKeys(for: scan.items)[1] == ItemKey(owner: "com.apple.controlcenter", detail: "Sound"))
        #expect(fixture.time == 0.2)
        #expect(fixture.timeouts.count == fixture.queried.count)
        #expect(fixture.timeouts.allSatisfy { $0.value > 0 && $0.value <= 0.75 })
        #expect(fixture.timeouts.first?.value == 0.75)
        #expect(fixture.queried.contains { CFEqual($0, fixture.bar) })
        #expect(fixture.queried.contains { CFEqual($0, fixture.child) })
        #expect(fixture.queried.contains { CFEqual($0, fixture.zeroChild) })
        for (timeout, queried) in zip(fixture.timeouts, fixture.queried) {
            #expect(CFEqual(timeout.element, queried))
        }
        let frame = try #require(scan.items.first?.frame)
        #expect(AccessibilityScanner.pressResult(itemAt: frame, in: scan, reader: fixture.reader) == .success)
        #expect(fixture.presses.count == 1)
        #expect(CFEqual(fixture.presses[0], fixture.child))
    }

    @Test(arguments: [AXError.cannotComplete, .apiDisabled, .failure, .noValue])
    func failedHostLeavesItemsUnidentified(error: AXError) {
        let fixture = Fixture()
        fixture.rootError = error
        let scan = fixture.scan()
        #expect(scan.items.count == 1)
        #expect(scan.items[0].bundleID == nil)
        #expect(scan.elements.isEmpty)
        #expect(ItemKeyAssigner.panelKeys(for: scan.items).isEmpty)
        #expect(fixture.presses.isEmpty)
    }

    @Test func wholeHostBudgetBoundsRepeatedSlowReads() {
        let fixture = Fixture()
        fixture.rootDelay = 0.6
        fixture.delay = 0.6
        let scan = fixture.scan()
        #expect(scan.elements.isEmpty)
        #expect(ItemKeyAssigner.panelKeys(for: scan.items).isEmpty)
        #expect(fixture.time <= 1.001)
        #expect(fixture.timeouts.count == 2)
        #expect(fixture.timeouts[1].value <= 0.401)
    }

    @Test(arguments: [kAXPositionAttribute, kAXSizeAttribute, kAXIdentifierAttribute])
    func failedChildReadDoesNotInventAStableIdentity(attribute: String) {
        let fixture = Fixture()
        fixture.failedAttribute = attribute
        let scan = fixture.scan()
        #expect(ItemKeyAssigner.panelKeys(for: scan.items).isEmpty)
        #expect(scan.items[0].detail == nil)
    }

    @Test func failedTimeoutSetupPreventsReadsAndPresses() {
        let fixture = Fixture()
        let scan = fixture.scan()
        fixture.timeoutError = .illegalArgument
        #expect(fixture.scan().elements.isEmpty)
        #expect(AccessibilityScanner.pressResult(itemAt: scan.items[0].frame, in: scan, reader: fixture.reader) == .illegalArgument)
        #expect(fixture.presses.isEmpty)
    }

    @Test func thirdPartyHostsKeepShortTimeouts() {
        let fixture = Fixture()
        let app = RunningAppInfo(pid: 60, name: "Third Party", bundleID: "com.example.app")
        let entries = AccessibilityScanner.extras(apps: [app], reader: fixture.reader)
        #expect(entries.count == 1)
        #expect(fixture.timeouts.allSatisfy { $0.value <= 0.1 })
        #expect(entries[0].item.detail == "Sound, muted", "Third-party descriptions keep existing behavior")
    }

    @Test func permissionDeniedDoesNotQueryAccessibility() {
        let fixture = Fixture()
        let scan = fixture.scan(trusted: false)
        #expect(fixture.queried.isEmpty)
        #expect(scan.elements.isEmpty)
        #expect(ItemKeyAssigner.panelKeys(for: scan.items).isEmpty)
    }

    @Test func freshPressRejectsDuplicateWindowsCompetingForOneElement() {
        let fixture = Fixture()
        var scan = fixture.scan()
        var duplicate = scan.items[0]
        duplicate.windowID = 2
        duplicate.frame = duplicate.frame.offsetBy(dx: 1, dy: 0)
        scan.items.append(duplicate)
        #expect(scan.elementIndex(itemAt: scan.items[0].frame) == nil)
        #expect(AccessibilityScanner.pressResult(itemAt: scan.items[0].frame, in: scan, reader: fixture.reader) == nil)
        #expect(fixture.presses.isEmpty)
    }

    @Test func freshPressRejectsDuplicateElementsAndNeverRetriesTimeouts() {
        let fixture = Fixture()
        var scan = fixture.scan()
        scan.elements.append(scan.elements[0])
        #expect(AccessibilityScanner.pressResult(itemAt: scan.items[0].frame, in: scan, reader: fixture.reader) == nil)
        #expect(fixture.presses.isEmpty)
        scan.elements.removeLast()
        var reader = fixture.reader
        reader.press = { fixture.presses.append($0); return .cannotComplete }
        #expect(AccessibilityScanner.pressResult(itemAt: scan.items[0].frame, in: scan, reader: reader) == .cannotComplete)
        #expect(fixture.presses.count == 1)
    }

    @Test @MainActor func identifiedSystemItemReachesPanelsLinksShortcutsAndQuickSearch() throws {
        let fixture = Fixture()
        let scan = fixture.scan()
        let row = MenuBarItemRow(
            item: scan.items[0], section: .hidden, visibility: .offScreen, overlapsNotch: false,
            barbackRole: nil, key: ItemKey(owner: "unused"), display: 0
        )
        let items = ItemsModel(snapshot: [row])
        let candidate = try #require(items.panelCandidates.first)
        let key = ItemKey(owner: "com.apple.controlcenter", detail: "Sound")
        #expect(candidate.key == key, "Settings Items uses this key for the recorder and Copy Link")
        #expect(candidate.title == "Control Centre — Sound")
        #expect(candidate.panelTitle == "Sound")
        #expect(BarbackURLRequest.parse(key.openURL) == .success(.open(.key(key))))
        #expect(ItemLinkResolver.resolve(.key(key), among: ItemLauncher.candidates(from: items.panelCandidates)) == .found(key))
        let panelItem = DropDownPanelItem(row: candidate)
        let group = ItemGroup(name: "System", itemKeys: [key])
        let panel = DropDownPanelModel()
        panel.boxes = DropDownPanelBox.make(items: [panelItem], groups: [group], defaultLayout: .list)
        #expect(panel.boxes.first?.items.map(\.key) == [key])
        panel.type("sound")
        #expect(panel.selectedResult?.key == key)
    }
}
