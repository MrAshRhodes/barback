/// Keeps the primary click, hotkey, and their presentation on the same action.
public struct PanelActionPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case togglePanel
        case toggleStrip
        case toggleAll
    }

    public enum Control: Equatable, Sendable {
        case openPanel
        case closePanel
        case showItems
        case hideItems
    }

    private let clickAction: ClickAction
    private let state: SectionState
    private let panelShown: Bool

    public init(clickAction: ClickAction, state: SectionState, panelShown: Bool) {
        self.clickAction = clickAction
        self.state = state
        self.panelShown = panelShown
    }

    public func action(optionPressed: Bool = false, isPrimaryIcon: Bool = true) -> Action {
        if optionPressed { return .toggleAll }
        return isPrimaryIcon && clickAction == .dropDown ? .togglePanel : .toggleStrip
    }

    public var control: Control {
        if clickAction == .dropDown { return panelShown ? .closePanel : .openPanel }
        return state.isRevealed ? .hideItems : .showItems
    }
}
