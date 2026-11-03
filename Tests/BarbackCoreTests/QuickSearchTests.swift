import Testing
@testable import BarbackCore

@Suite("Quick search")
struct QuickSearchTests {
    private struct Entry: Equatable {
        var title: String
        var app: String = ""
    }

    private func titles(_ entries: [Entry], _ query: String) -> [String] {
        QuickSearch.filter(entries, query: query) { [$0.title, $0.app] }.map(\.title)
    }

    @Test func emptyQueryKeepsEveryItemInOriginalOrder() {
        let entries = [Entry(title: "Zoom"), Entry(title: "Alfred"), Entry(title: "Wi-Fi")]
        #expect(titles(entries, "") == ["Zoom", "Alfred", "Wi-Fi"])
        #expect(titles(entries, "   ") == ["Zoom", "Alfred", "Wi-Fi"])
    }

    @Test func ignoresCaseDiacriticsAndWidth() {
        let entries = [Entry(title: "Café Menu"), Entry(title: "ÉCRAN"), Entry(title: "Other")]
        #expect(titles(entries, "cafe") == ["Café Menu"])
        #expect(titles(entries, "CAFÉ") == ["Café Menu"])
        #expect(titles(entries, "ecran") == ["ÉCRAN"])
        // Decomposed input (e + combining acute) and full-width letters fold the same way.
        #expect(titles(entries, "e\u{301}cran") == ["ÉCRAN"])
        #expect(titles(entries, "ＣＡＦＥ") == ["Café Menu"])
    }

    @Test func ranksPrefixThenWordPrefixThenSubstring() {
        let entries = [
            Entry(title: "Unclipped"),          // substring "clip"
            Entry(title: "Paste — Clipboard"),  // word prefix
            Entry(title: "Clipy"),              // prefix
            Entry(title: "Battery"),            // no match
        ]
        #expect(titles(entries, "clip") == ["Clipy", "Paste — Clipboard", "Unclipped"])
        #expect(QuickSearch.match(query: "clip", terms: ["Clipy"]) == .prefix)
        #expect(QuickSearch.match(query: "clip", terms: ["Paste — Clipboard"]) == .wordPrefix)
        #expect(QuickSearch.match(query: "clip", terms: ["Unclipped"]) == .substring)
        #expect(QuickSearch.match(query: "clip", terms: ["Battery"]) == nil)
    }

    @Test func equallyRankedMatchesKeepOriginalOrder() {
        let entries = [Entry(title: "Drive B"), Entry(title: "Dropbox"), Entry(title: "Drive A")]
        #expect(titles(entries, "dr") == ["Drive B", "Dropbox", "Drive A"])
    }

    @Test func matchesAppNameAsWellAsTitle() {
        let entries = [Entry(title: "Wi-Fi", app: "Control Center"), Entry(title: "Status", app: "Tailscale")]
        #expect(titles(entries, "tail") == ["Status"])
        #expect(titles(entries, "control") == ["Wi-Fi"])
    }

    @Test func everyQueryWordMustMatch() {
        let entries = [Entry(title: "Wi-Fi"), Entry(title: "Wireless Mouse")]
        #expect(titles(entries, "wi fi") == ["Wi-Fi"])
        #expect(titles(entries, "wifi") == ["Wi-Fi"])
        #expect(titles(entries, "mouse wire") == ["Wireless Mouse"])
        #expect(titles(entries, "mouse fi").isEmpty)
    }

    @Test func typedTextSkipsKeysThatDoNotType() {
        #expect(QuickSearch.typedText("a") == "a")
        #expect(QuickSearch.typedText("é") == "é")
        #expect(QuickSearch.typedText(" ") == " ")
        #expect(QuickSearch.typedText(nil) == nil)
        #expect(QuickSearch.typedText("") == nil)
        #expect(QuickSearch.typedText("\r") == nil)
        #expect(QuickSearch.typedText("\t") == nil)
        #expect(QuickSearch.typedText("\u{7F}") == nil)
        #expect(QuickSearch.typedText("\u{F700}") == nil) // NSUpArrowFunctionKey
    }

    @Test func selectionClampsToResults() {
        #expect(QuickSearchSelection.clamped(nil, count: 0) == nil)
        #expect(QuickSearchSelection.clamped(3, count: 0) == nil)
        #expect(QuickSearchSelection.clamped(nil, count: 4) == 0)
        #expect(QuickSearchSelection.clamped(2, count: 4) == 2)
        #expect(QuickSearchSelection.clamped(7, count: 4) == 3)
        #expect(QuickSearchSelection.clamped(-1, count: 4) == 0)
    }

    @Test func selectionWrapsAround() {
        #expect(QuickSearchSelection.moved(nil, by: 1, count: 3) == 0)
        #expect(QuickSearchSelection.moved(nil, by: -1, count: 3) == 2)
        #expect(QuickSearchSelection.moved(0, by: 1, count: 3) == 1)
        #expect(QuickSearchSelection.moved(2, by: 1, count: 3) == 0)
        #expect(QuickSearchSelection.moved(0, by: -1, count: 3) == 2)
        #expect(QuickSearchSelection.moved(1, by: -4, count: 3) == 0)
        #expect(QuickSearchSelection.moved(1, by: 1, count: 0) == nil)
    }
}
