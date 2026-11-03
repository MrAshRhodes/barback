import AppKit
import BarbackCore
import SwiftUI

struct DropDownPanelItem: Identifiable, Equatable {
    let id: UInt32
    let key: ItemKey
    let title: String
    let icon: NSImage?
    let fallbackSymbol: String
    let display: Int?
    let revealAction: SectionAction?
    /// The app's name when it says more than the title, shown under search results.
    let subtitle: String?
    /// What quick search matches: the title, the app's name and the item's own description.
    let searchTerms: [String]

    @MainActor
    init(row: MenuBarItemRow) {
        id = row.id
        key = row.key
        title = row.panelTitle
        icon = ItemIcons.image(for: row.item)
        fallbackSymbol = ItemIcons.symbol(for: row.item)
        display = row.display
        revealAction = row.visibility == .shown ? nil : row.section == .alwaysHidden ? .showAll : .show
        let appName = row.item.displayName
        subtitle = row.barbackRole == nil && appName != title && !row.item.isSystemItem ? appName : nil
        searchTerms = [title, appName, row.item.detail].compactMap { $0 }
    }
}

struct DropDownPanelBox: Identifiable, Equatable {
    var id: UUID
    var title: String
    var symbol: String
    var layout: DropDownLayout
    var items: [DropDownPanelItem]
    var unavailableCount: Int

    /// Only explicit selections appear, in saved order. Missing items never become an implicit "Other" box.
    static func make(
        items: [DropDownPanelItem], groups: [ItemGroup], defaultLayout: DropDownLayout
    ) -> [DropDownPanelBox] {
        let lookup = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return groups.map { group in
            let selected = group.itemKeys.compactMap { lookup[$0] }
            return DropDownPanelBox(
                id: group.id, title: group.name, symbol: group.symbol,
                layout: group.layout ?? defaultLayout, items: selected,
                unavailableCount: group.itemKeys.count - selected.count
            )
        }
    }
}

enum DropDownPanelChrome: Equatable {
    case glass, material, solid

    static func current() -> DropDownPanelChrome {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { return .solid }
        if #available(macOS 26.0, *) { return .glass }
        return .material
    }
}

@MainActor
final class DropDownPanelModel: ObservableObject {
    @Published var boxes: [DropDownPanelBox] = []
    @Published var isLoading = false
    @Published var canOpenItems = false
    @Published var unidentifiedItemCount = 0
    @Published var errorMessage: String?
    @Published var chrome: DropDownPanelChrome = .material
    @Published var maxContentHeight: CGFloat = DropDownPanelView.defaultMaxContentHeight
    /// What has been typed while the panel is open; empty shows the panels as usual.
    @Published private(set) var query = ""
    /// Index into `results` of the highlighted result.
    @Published private(set) var selection: Int?
    var onOpen: (DropDownPanelItem) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onEditPanel: (UUID) -> Void = { _ in }
    var onAllowAccessibility: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onReveal: () -> Void = {}

    // MARK: Quick search

    var isSearching: Bool { !QuickSearch.normalize(query).isEmpty }

    /// Every item in the panels once (an item can be in several), best match first.
    var results: [DropDownPanelItem] {
        var seen = Set<UInt32>()
        let items = boxes.flatMap(\.items).filter { seen.insert($0.id).inserted }
        return QuickSearch.filter(items, query: query) { $0.searchTerms }
    }

    var selectedResult: DropDownPanelItem? {
        let results = results
        guard let selection, results.indices.contains(selection) else { return nil }
        return results[selection]
    }

    func type(_ text: String) {
        setQuery(query + text)
    }

    func deleteBackward() {
        guard !query.isEmpty else { return }
        setQuery(String(query.dropLast()))
    }

    func clearQuery() {
        setQuery("")
    }

    func moveSelection(by offset: Int) {
        selection = QuickSearchSelection.moved(selection, by: offset, count: results.count)
    }

    func select(_ item: DropDownPanelItem) {
        selection = results.firstIndex { $0.id == item.id }
    }

    /// Keeps the highlight on a result after the items changed (a scan finishing).
    func clampSelection() {
        let clamped = isSearching ? QuickSearchSelection.clamped(selection, count: results.count) : nil
        if clamped != selection { selection = clamped }
    }

    /// A new query highlights its best match.
    private func setQuery(_ text: String) {
        query = text
        selection = isSearching ? QuickSearchSelection.clamped(nil, count: results.count) : nil
    }
}

private enum Metrics {
    static let tileRadius: CGFloat = 20
    static let gap: CGFloat = 10
    static let padding: CGFloat = 14
}

struct DropDownPanelView: View {
    static let width: CGFloat = 340
    static let defaultMaxContentHeight: CGFloat = 440
    /// Height the search field adds above the scrolling content while a query is typed.
    static let searchFieldHeight: CGFloat = 46

    @ObservedObject var model: DropDownPanelModel

    var body: some View {
        VStack(spacing: Metrics.gap) {
            header
            if model.isSearching {
                SearchFieldView(model: model)
            }
            ScrollViewReader { proxy in
                ScrollView { scrollContent }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: model.maxContentHeight)
                    .onChange(of: model.selectedResult?.id) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(SearchResultsView.rowID(id))
                    }
            }
        }
        .padding(Metrics.padding)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Barback Panels"))
    }

    private var scrollContent: some View {
        VStack(spacing: Metrics.gap) {
            if let error = model.errorMessage {
                failureNotice(error)
            }
            if !model.canOpenItems {
                accessibilityNotice
            }
            if model.isSearching {
                SearchResultsView(model: model)
            } else if model.boxes.isEmpty {
                emptyState
            } else {
                PanelGlassContainer(chrome: model.chrome) { moduleGrid }
            }
            if model.unidentifiedItemCount > 0 {
                Text("Unidentified or ambiguous items are not included. System items need a recognized stable Accessibility identifier. Manage available items in Panel Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
        .padding(1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Panels")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if model.isLoading {
                ProgressView().controlSize(.small)
                    .frame(width: 40, height: 40)
                    .accessibilityLabel(Text("Scanning items"))
            } else {
                Button { model.onRefresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(PanelCircleButtonStyle(chrome: model.chrome, diameter: 40))
                .accessibilityLabel(Text("Refresh Items"))
                .help(Text("Refresh Items"))
            }
            Button { model.onOpenSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(PanelCircleButtonStyle(chrome: model.chrome, diameter: 40))
            .accessibilityLabel(Text("Panel Settings"))
            .help(Text("Configure Panels"))
        }
        .padding(.leading, 4)
    }

    private var moduleGrid: some View {
        let boxes = model.boxes
        let rows = DropDownModuleGrid.rows(compact: boxes.map {
            $0.unavailableCount == 0 && !$0.items.isEmpty
                && DropDownModuleGrid.isCompact(itemCount: $0.items.count, layout: $0.layout)
        })
        return VStack(spacing: Metrics.gap) {
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .top, spacing: Metrics.gap) {
                    ForEach(row, id: \.self) { index in
                        DropDownBoxView(box: boxes[index], model: model)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Make it your menu bar")
                .font(.headline)
            Text("Create a panel and choose its items, name and layout. Only your selections appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Configure Panels") { model.onOpenSettings() }
                .barbackProminentButton()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .platter(model.chrome)
        .accessibilityElement(children: .contain)
    }

    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Allow Accessibility to open items", systemImage: "hand.raised")
                .font(.headline)
            Text("Accessibility is needed to identify system items such as Wi-Fi and Bluetooth and to open an item's menu. You can still reveal icons in the menu bar without permission.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Accessibility...") { model.onAllowAccessibility() }
                .barbackProminentButton()
            Button("Show in Menu Bar") { model.onReveal() }
                .barbackButton()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .platter(model.chrome, subtle: true)
    }

    private func failureNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Could not open item", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show in Menu Bar") { model.onReveal() }
                .barbackButton()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .platter(model.chrome, subtle: true)
    }
}

struct SearchFieldView: View {
    @ObservedObject var model: DropDownPanelModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.query.isEmpty ? "Search menu bar items" : model.query)
                .lineLimit(1)
                .foregroundStyle(model.query.isEmpty ? .secondary : .primary)
            Spacer(minLength: 0)
            if !model.query.isEmpty {
                Text("\(model.results.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: DropDownPanelView.searchFieldHeight)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Search menu bar items"))
        .accessibilityValue(Text(model.query))
    }
}

struct SearchResultsView: View {
    @ObservedObject var model: DropDownPanelModel

    static func rowID(_ id: UInt32) -> String { "quick-search-result-\(id)" }

    var body: some View {
        if model.results.isEmpty {
            Text("No matching items")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 72)
                .accessibilityLabel(Text("No matching menu bar items"))
        } else {
            VStack(spacing: 2) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                    Button {
                        model.onOpen(item)
                    } label: {
                        HStack(spacing: 10) {
                            PanelItemIcon(item: item, size: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        .background {
                            if model.selection == index {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.16))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canOpenItems || model.isLoading)
                    .help(item.title)
                    .accessibilityLabel(Text(item.title))
                    .accessibilityHint(Text(model.canOpenItems ? "Opens this item's menu" : "Requires Accessibility permission"))
                    .id(Self.rowID(item.id))
                    .onHover { if $0 { model.select(item) } }
                }
            }
        }
    }
}

struct DropDownBoxView: View {
    let box: DropDownPanelBox
    @ObservedObject var model: DropDownPanelModel

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 8, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: box.symbol).accessibilityHidden(true)
                Text(box.title)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { model.onEditPanel(box.id) } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Edit \(box.title)"))
                .help(Text("Edit Panel"))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)

            if box.items.isEmpty && box.unavailableCount == 0 {
                Text("No items selected").font(.footnote).foregroundStyle(.secondary)
                Button("Add Items") { model.onEditPanel(box.id) }.barbackButton()
            } else {
                switch box.layout {
                case .list:
                    VStack(spacing: 0) {
                        ForEach(box.items) { item in
                            itemButton(item, grid: false)
                        }
                    }
                case .grid:
                    LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
                        ForEach(box.items) { item in
                            itemButton(item, grid: true)
                        }
                    }
                }
                if box.unavailableCount > 0 {
                    Label("\(box.unavailableCount) unavailable", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Not running or not safely identified. Your selections are saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .platter(model.chrome)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(box.title))
    }

    private func itemButton(_ item: DropDownPanelItem, grid: Bool) -> some View {
        Button { model.onOpen(item) } label: {
            Group {
                if grid {
                    VStack(spacing: 6) {
                        PanelItemIcon(item: item, size: 28)
                        Text(item.title)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .top)
                    .padding(.vertical, 6)
                } else {
                    HStack(spacing: 8) {
                        PanelItemIcon(item: item, size: 22)
                        Text(item.title).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(minHeight: 40)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowButtonStyle(cornerRadius: 10))
        .disabled(!model.canOpenItems || model.isLoading)
        .help(item.title)
        .accessibilityLabel(Text(item.title))
        .accessibilityHint(Text(model.canOpenItems ? "Opens this item's menu" : "Requires Accessibility permission"))
    }
}

private struct PanelItemIcon: View {
    let item: DropDownPanelItem
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.fallbackSymbol)
                    .resizable().aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// Observable state also supports Command Line Tools builds without SwiftUI's State macro plugin.
private final class PanelHover: ObservableObject {
    @Published var isOver = false
}

private struct PanelRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct RowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @StateObject private var hover = PanelHover()
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.16 : hover.isOver ? 0.10 : 0) : 0))
                )
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
                .onHover { hover.isOver = $0 }
        }
    }
}

private struct PanelCircleButtonStyle: ButtonStyle {
    var chrome: DropDownPanelChrome
    var diameter: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        CircleButtonBody(configuration: configuration, chrome: chrome, diameter: diameter)
    }

    private struct CircleButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let chrome: DropDownPanelChrome
        let diameter: CGFloat
        @StateObject private var hover = PanelHover()
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .frame(width: diameter, height: diameter)
                .modifier(DiscSurface(chrome: chrome))
                .overlay(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.20 : hover.isOver ? 0.14 : 0.07)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0), lineWidth: 1))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
                .onHover { hover.isOver = $0 }
        }
    }

    private struct DiscSurface: ViewModifier {
        let chrome: DropDownPanelChrome

        @ViewBuilder
        func body(content: Content) -> some View {
            switch chrome {
            case .glass:
                if #available(macOS 26.0, *) {
                    content.glassEffect(.regular.interactive(), in: Circle())
                } else {
                    content.background(.thinMaterial, in: Circle())
                }
            case .material:
                content.background(.thinMaterial, in: Circle())
            case .solid:
                content.background(Color.primary.opacity(0.1), in: Circle())
            }
        }
    }
}

private struct PanelGlassContainer<Content: View>: View {
    let chrome: DropDownPanelChrome
    @ViewBuilder var content: () -> Content

    var body: some View {
        if chrome == .glass, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { content() }
        } else {
            content()
        }
    }
}

private struct Platter: ViewModifier {
    let chrome: DropDownPanelChrome
    let subtle: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
        surface(content, shape: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0), lineWidth: 1))
    }

    @ViewBuilder
    private func surface(_ content: Content, shape: RoundedRectangle) -> some View {
        if subtle || chrome == .solid {
            content.background(Color.primary.opacity(subtle ? 0.06 : 0.08), in: shape)
        } else if chrome == .glass, #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(Color.white.opacity(scheme == .light ? 0.22 : 0.03)), in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}

private extension View {
    func platter(_ chrome: DropDownPanelChrome, subtle: Bool = false) -> some View {
        modifier(Platter(chrome: chrome, subtle: subtle))
    }
}
