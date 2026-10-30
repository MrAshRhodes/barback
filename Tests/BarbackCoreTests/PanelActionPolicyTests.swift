import Testing
@testable import BarbackCore

@Suite("Panel actions")
struct PanelActionPolicyTests {
    @Test func dropDownActionAndControlDoNotChangeWhenStripIsRevealed() {
        for state in [SectionState.hidden, .shown, .shownAll] {
            let closed = PanelActionPolicy(clickAction: .dropDown, state: state, panelShown: false)
            let open = PanelActionPolicy(clickAction: .dropDown, state: state, panelShown: true)
            #expect(closed.action() == .togglePanel)
            #expect(open.action() == .togglePanel)
            #expect(closed.control == .openPanel)
            #expect(open.control == .closePanel)
        }
    }

    @Test func stripModeKeepsItsShowHideControl() {
        for state in [SectionState.hidden, .shown, .shownAll] {
            let policy = PanelActionPolicy(clickAction: .revealStrip, state: state, panelShown: true)
            #expect(policy.action() == .toggleStrip)
            #expect(policy.control == (state.isRevealed ? .hideItems : .showItems))
        }
    }

    @Test func optionClickIncludesAllAndSeparatorsNeverOpenThePanel() {
        for mode in ClickAction.allCases {
            for state in [SectionState.hidden, .shown, .shownAll] {
                let policy = PanelActionPolicy(clickAction: mode, state: state, panelShown: false)
                #expect(policy.action(optionPressed: true) == .toggleAll)
                #expect(policy.action(optionPressed: true, isPrimaryIcon: false) == .toggleAll)
                #expect(policy.action(isPrimaryIcon: false) == .toggleStrip)
            }
        }
    }
}
