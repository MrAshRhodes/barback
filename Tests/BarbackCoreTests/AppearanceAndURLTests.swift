import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import BarbackCore

@Suite("Appearance")
struct AppearanceTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "barback.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func defaultsMatchClassicStyle() {
        let a = AppearanceSettings.default
        #expect(a.toggleIcon == .chevron)
        #expect(a.iconWeight == .semibold)
        #expect(!a.tintWhenShowing)
        #expect(a.extraDividerCount == 0)
        #expect(a.style == .classic)
        #expect(BarbackSettings.default.appearance == .default)
        #expect(!BarbackSettings.default.rehideOnAppSwitch)
    }

    @Test func saveLoadRoundTripIncludesAppearance() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: d)
        let appearance = AppearanceSettings(
            toggleIcon: .wineglass,
            iconWeight: .bold,
            tintWhenShowing: true,
            hiddenDivider: .doubleLine,
            alwaysHiddenDivider: .none,
            extraDividerCount: 2,
            extraDividerStyle: .dot
        )
        let custom = BarbackSettings(rehideOnAppSwitch: true, appearance: appearance)
        store.save(custom)
        #expect(store.load() == custom)
        #expect(d.string(forKey: SettingsKey.toggleIcon.rawValue) == "wineglass", "stored as plain strings for `defaults write`")
        store.reset()
        #expect(store.load() == .default)
    }

    @Test func unknownStoredValuesFallBackAndCountsClamp() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        d.set("sparkles-from-the-future", forKey: SettingsKey.toggleIcon.rawValue)
        d.set("heavy", forKey: SettingsKey.iconWeight.rawValue)
        d.set("zigzag", forKey: SettingsKey.hiddenDividerStyle.rawValue)
        d.set(42, forKey: SettingsKey.extraDividerCount.rawValue)
        let a = SettingsStore(defaults: d).load().appearance
        #expect(a.toggleIcon == .default)
        #expect(a.iconWeight == .default)
        #expect(a.hiddenDivider == AppearanceSettings.default.hiddenDivider)
        #expect(a.extraDividerCount == AppearanceSettings.maxExtraDividers)
        #expect(AppearanceSettings(extraDividerCount: -4).sanitized().extraDividerCount == 0)
    }

    @Test func stylesAreDistinctAndApplyKeepsPersonalChoices() {
        let combos = AppearanceStyle.allCases.map { "\($0.toggleIcon)/\($0.hiddenDivider)/\($0.alwaysHiddenDivider)" }
        #expect(Set(combos).count == combos.count, "each style must be recognisable by matching()")
        for style in AppearanceStyle.allCases {
            var a = AppearanceSettings(iconWeight: .bold, tintWhenShowing: true, extraDividerCount: 3, extraDividerStyle: .dot)
            a.apply(style)
            #expect(a.style == style)
            #expect(a.iconWeight == .bold)
            #expect(a.tintWhenShowing)
            #expect(a.extraDividerCount == 3)
            #expect(a.extraDividerStyle == .dot)
        }
        var custom = AppearanceSettings.default
        custom.toggleIcon = .mug
        #expect(custom.style == nil, "an unmatched combination is Custom")
    }

    @Test func dividerSegmentsFitTheCanvas() {
        let canvas = CGRect(origin: .zero, size: DividerStyle.canvasSize)
        for style in DividerStyle.allCases {
            for segment in style.segments {
                #expect(canvas.contains(segment.rect), "\(style) segment \(segment.rect) leaves the canvas")
                #expect(segment.rect.width > 0 && segment.rect.height > 0)
                #expect(segment.cornerRadius <= min(segment.rect.width, segment.rect.height) / 2 + 0.001)
            }
        }
        #expect(DividerStyle.none.segments.isEmpty)
        #expect(DividerStyle.chevron.segments.isEmpty)
        #expect(DividerStyle.chevron.symbolName != nil)
        #expect(DividerStyle.dashed.segments.count > 1)
        #expect(!DividerStyle.none.isVisible)
        #expect(DividerStyle.none.collapsedLength < DividerStyle.line.collapsedLength)
        #expect(DividerStyle.none.collapsedLength > 0, "an invisible divider must stay grabbable")
    }

    @Test func toggleIconsChangeWithState() {
        for style in ToggleIconStyle.allCases {
            #expect(style.symbolName(revealed: true) != style.symbolName(revealed: false), "\(style) must show state")
        }
    }

    @Test func everySymbolExistsOnThisSystem() {
        var names = ToggleIconStyle.allCases.flatMap { [$0.symbolName(revealed: true), $0.symbolName(revealed: false)] }
        names += DividerStyle.allCases.compactMap(\.symbolName)
        names += [ToggleIconStyle.fallbackSymbolName(revealed: true), ToggleIconStyle.fallbackSymbolName(revealed: false)]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)")
        }
    }

    @Test func collapsedLengthsFollowDividerStyles() {
        let collapsed = SeparatorLengths(hidden: DividerStyle.none.collapsedLength, alwaysHidden: DividerStyle.line.collapsedLength)
        let shownAll = SectionLayout.lengths(for: .shownAll, validation: .valid, alwaysHiddenEnabled: true, collapsed: collapsed)
        #expect(shownAll == collapsed)
        let shown = SectionLayout.lengths(for: .shown, validation: .valid, alwaysHiddenEnabled: true, collapsed: collapsed)
        #expect(shown.hidden == DividerStyle.none.collapsedLength)
        #expect(shown.alwaysHidden == SectionLayout.expandedLength)
        let misplaced = SectionLayout.lengths(for: .hidden, validation: .hiddenSeparatorMisplaced, alwaysHiddenEnabled: true, collapsed: collapsed)
        #expect(misplaced == collapsed, "a misplaced separator never expands")
        #expect(SectionLayout.lengths(for: .shownAll, validation: .valid, alwaysHiddenEnabled: false) == SectionLayout.defaultCollapsed)
    }
}

@Suite("URL scheme")
struct URLCommandTests {
    private func parse(_ s: String) -> BarbackURLCommand? {
        URL(string: s).flatMap(BarbackURLCommand.parse)
    }

    @Test func parsesEveryCommandFromItsURL() {
        for command in BarbackURLCommand.allCases {
            #expect(BarbackURLCommand.parse(command.url) == command)
        }
    }

    @Test func acceptsCommonSpellings() {
        #expect(parse("barback://toggle") == .toggle)
        #expect(parse("BARBACK://Show-All") == .showAll)
        #expect(parse("barback:toggle") == .toggle)
        #expect(parse("barback:///hide") == .hide)
        #expect(parse("barback://hide/") == .hide)
        #expect(parse("barback://show?source=shortcuts") == .show)
        #expect(parse("barback://reveal") == .show)
        #expect(parse("barback://showall") == .showAll)
        #expect(parse("barback://toggleall") == .toggleAll)
        #expect(parse("barback://preferences") == .settings)
    }

    @Test func rejectsOtherSchemesAndUnknownCommands() {
        #expect(parse("https://toggle") == nil)
        #expect(parse("barback://") == nil)
        #expect(parse("barback://explode") == nil)
        #expect(parse("barback://set?autoRehide=0") == nil)
    }

    @Test func commandsMapToSectionActions() {
        #expect(BarbackURLCommand.settings.sectionAction == nil)
        #expect(BarbackURLCommand.allCases.filter { $0.sectionAction == nil } == [.settings])
        #expect(BarbackURLCommand.toggle.url.absoluteString == "barback://toggle")
    }
}
