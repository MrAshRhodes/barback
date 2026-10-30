import AppKit
import BarbackCore
import SwiftUI

// MARK: - Data

/// One hidden item as the panel shows it.
struct DropDownPanelItem: Identifiable, Equatable {
    /// The item's window ID in the scan that produced it.
    let id: UInt32
    /// Identity that survives relaunches.
    let key: ItemKey
    let title: String
    let icon: NSImage?
    let fallbackSymbol: String
    let display: Int?
    /// Which section the item came from; decides how much needs revealing to reach it.
    let box: DropDownContent.Box

    /// Always-hidden items live in their own box and can't be moved into a group.
    var canGroup: Bool { box == .hidden }
}

/// One box of the panel: a group, the ungrouped rest ("Other"), or the always-hidden section.
struct DropDownPanelBox: Identifiable, Equatable {
    enum Kind: Equatable {
        case group(UUID)
        case other
        case alwaysHidden
    }

    var kind: Kind
    var title: String
    var symbol: String
    var items: [DropDownPanelItem]
    /// Without any groups a lone "Other" heading says nothing, so the box shows just its items.
    var showsTitle = true

    var id: String {
        switch kind {
        case .group(let id): return id.uuidString
        case .other: return "other"
        case .alwaysHidden: return "alwaysHidden"
        }
    }

    var groupID: UUID? {
        if case .group(let id) = kind { return id }
        return nil
    }

    /// Groups in the user's order (empty ones left out), then the ungrouped items, then the always-hidden box.
    static func make(
        hidden: [DropDownPanelItem],
        alwaysHidden: [DropDownPanelItem],
        groups: [ItemGroup]
    ) -> [DropDownPanelBox] {
        var boxes = ItemGroups.partition(hidden, groups: groups, key: \.key).map { part -> DropDownPanelBox in
            if let group = part.group {
                return DropDownPanelBox(kind: .group(group.id), title: group.name, symbol: group.symbol, items: part.items)
            }
            return DropDownPanelBox(
                kind: .other, title: String(localized: "Other"), symbol: "ellipsis.circle", items: part.items,
                showsTitle: !groups.isEmpty
            )
        }
        if !alwaysHidden.isEmpty {
            boxes.append(DropDownPanelBox(
                kind: .alwaysHidden, title: String(localized: "Always Hidden"), symbol: "eye.slash", items: alwaysHidden
            ))
        }
        return boxes
    }
}

/// How the panel and its tiles are drawn.
enum DropDownPanelChrome: Equatable {
    /// Liquid Glass (macOS 26).
    case glass
    /// Blurred materials, for earlier systems.
    case material
    /// Opaque, for Reduce Transparency.
    case solid

    static func current() -> DropDownPanelChrome {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { return .solid }
        if #available(macOS 26.0, *) { return .glass }
        return .material
    }
}

/// Everything the panel view shows and every way it can act, so the view needs nothing but this.
@MainActor
final class DropDownPanelModel: ObservableObject {
    @Published var boxes: [DropDownPanelBox] = []
    @Published var layout: DropDownLayout = .list
    @Published var groups: [ItemGroup] = []
    @Published var isLoading = false
    @Published var showsAccessibilityHint = false
    /// False once the group limit is reached.
    @Published var canAddGroup = true
    @Published var chrome: DropDownPanelChrome = .material
    /// How tall the boxes may grow before they scroll; the controller lowers it on short screens.
    @Published var maxContentHeight: CGFloat = DropDownPanelView.defaultMaxContentHeight
    var onOpen: (DropDownPanelItem) -> Void = { _ in }
    /// `nil` moves the item out of its group.
    var onMove: (DropDownPanelItem, UUID?) -> Void = { _, _ in }
    var onNewGroup: (DropDownPanelItem) -> Void = { _ in }
    var onSetLayout: (DropDownLayout) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onAllowAccessibility: () -> Void = {}
    var onDismissAccessibilityHint: () -> Void = {}
}

// MARK: - Panel

private enum Metrics {
    static let tileRadius: CGFloat = 20
    static let gap: CGFloat = 10
    static let padding: CGFloat = 14
    static let circle: CGFloat = 46
    static let smallCircle: CGFloat = 28
}

/// The drop-down panel's content, laid out like Control Center: a header row, then boxes as rounded tiles
/// (two small ones to a row, large ones across the whole width). The window around it supplies the glass.
struct DropDownPanelView: View {
    static let width: CGFloat = 340
    static let defaultMaxContentHeight: CGFloat = 440

    @ObservedObject var model: DropDownPanelModel

    var body: some View {
        VStack(spacing: Metrics.gap) {
            header
            content
            if model.showsAccessibilityHint { accessibilityHint }
        }
        .padding(Metrics.padding)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Hidden Items"))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Hidden Items")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if model.isLoading, !model.boxes.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Scanning"))
            }
            Spacer(minLength: 8)
            PanelGlassContainer(chrome: model.chrome) {
                HStack(spacing: 8) {
                    Button {
                        model.onSetLayout(model.layout == .list ? .grid : .list)
                    } label: {
                        Image(systemName: model.layout == .list ? "square.grid.2x2" : "list.bullet")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(PanelCircleButtonStyle(chrome: model.chrome, diameter: Metrics.smallCircle))
                    .accessibilityLabel(Text(model.layout == .list ? "Show as Grid" : "Show as List"))
                    .help(Text(model.layout == .list ? "Show as Grid" : "Show as List"))

                    Button {
                        model.onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(PanelCircleButtonStyle(chrome: model.chrome, diameter: Metrics.smallCircle))
                    .accessibilityLabel(Text("Panel Settings"))
                    .help(Text("Panel Settings"))
                }
            }
        }
        .padding(.leading, 4)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.boxes.isEmpty {
            emptyState
        } else {
            ScrollView {
                PanelGlassContainer(chrome: model.chrome) { moduleGrid }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: model.maxContentHeight)
        }
    }

    private var moduleGrid: some View {
        let boxes = model.boxes
        let rows = DropDownModuleGrid.rows(
            compact: boxes.map { DropDownModuleGrid.isCompact(itemCount: $0.items.count, layout: model.layout) }
        )
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

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityHidden(true)
                Text("Scanning…")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No Hidden Items")
                    .font(.headline)
                Text("Hold ⌘ and drag icons to the left of the │ separator to hide them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .platter(model.chrome)
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var accessibilityHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Allow Accessibility so Barback can open items from here")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Allow…") { model.onAllowAccessibility() }
                    .barbackButton()
                    .controlSize(.small)
                Button("Dismiss") { model.onDismissAccessibilityHint() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 24)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .platter(model.chrome, subtle: true)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Boxes

private struct DropDownBoxView: View {
    let box: DropDownPanelBox
    @ObservedObject var model: DropDownPanelModel

    private let columns = [GridItem(.adaptive(minimum: Metrics.circle), spacing: 8, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if box.showsTitle {
                HStack(spacing: 5) {
                    Image(systemName: box.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(box.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            switch model.layout {
            case .list:
                VStack(spacing: 0) {
                    ForEach(box.items) { item in
                        DropDownRow(item: item, box: box, model: model)
                    }
                }
            case .grid:
                LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
                    ForEach(box.items) { item in
                        DropDownCircle(item: item, box: box, model: model)
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .platter(model.chrome)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(box.title))
    }
}

private struct DropDownRow: View {
    let item: DropDownPanelItem
    let box: DropDownPanelBox
    @ObservedObject var model: DropDownPanelModel

    var body: some View {
        Button {
            model.onOpen(item)
        } label: {
            HStack(spacing: 8) {
                PanelItemIcon(item: item, size: 22)
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowButtonStyle(cornerRadius: 10))
        .panelItemMenu(item: item, box: box, model: model)
        .panelItemAccessibility(item)
    }
}

/// A round button like Control Center's toggles, holding the item's icon; the name is the tooltip.
private struct DropDownCircle: View {
    let item: DropDownPanelItem
    let box: DropDownPanelBox
    @ObservedObject var model: DropDownPanelModel

    var body: some View {
        Button {
            model.onOpen(item)
        } label: {
            PanelItemIcon(item: item, size: 28)
        }
        .buttonStyle(PanelCircleButtonStyle(chrome: model.chrome, diameter: Metrics.circle))
        .help(item.title)
        .panelItemMenu(item: item, box: box, model: model)
        .panelItemAccessibility(item)
    }
}

private struct PanelItemIcon: View {
    let item: DropDownPanelItem
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.fallbackSymbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Item behaviour

private extension View {
    func panelItemAccessibility(_ item: DropDownPanelItem) -> some View {
        self.accessibilityLabel(Text(item.title))
            .accessibilityHint(Text("Opens this item’s menu"))
    }

    func panelItemMenu(item: DropDownPanelItem, box: DropDownPanelBox, model: DropDownPanelModel) -> some View {
        self.contextMenu {
            Button("Open") { model.onOpen(item) }
            if item.canGroup {
                Divider()
                Menu("Move to Group") {
                    ForEach(model.groups) { group in
                        Toggle(isOn: Binding(
                            get: { box.groupID == group.id },
                            set: { _ in model.onMove(item, group.id) }
                        )) {
                            Label(group.name, systemImage: group.symbol)
                        }
                    }
                    if !model.groups.isEmpty { Divider() }
                    Toggle("Ungrouped", isOn: Binding(
                        get: { box.groupID == nil },
                        set: { _ in model.onMove(item, nil) }
                    ))
                    Divider()
                    Button("New Group…") { model.onNewGroup(item) }
                        .disabled(!model.canAddGroup)
                }
            }
        }
    }
}

// MARK: - Buttons

/// Tracks the pointer. (An observable object stands in for `@State`, which needs a toolchain with the SwiftUI
/// macro plugin; command-line-tools-only builds lack it.)
private final class PanelHover: ObservableObject {
    @Published var isOver = false
}

/// Flat button that lights up under the pointer, like a menu row.
private struct PanelRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct RowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @StateObject private var hover = PanelHover()

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hover.isOver ? 0.10 : 0))
                )
                .onHover { hover.isOver = $0 }
        }
    }
}

/// Round button with its own glass (or material) disc, which brightens under the pointer.
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

        var body: some View {
            configuration.label
                .frame(width: diameter, height: diameter)
                .modifier(DiscSurface(chrome: chrome))
                .overlay(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.20 : hover.isOver ? 0.14 : 0.07)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0), lineWidth: 1))
                .contentShape(Circle())
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

// MARK: - Tiles

/// Lets Liquid Glass tiles share one rendering pass on macOS 26.
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

/// A Control Center "module": a rounded tile of glass (macOS 26), material (earlier) or a flat tint (Reduce
/// Transparency), with a visible border under Increase Contrast.
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
            // A touch of white keeps the tiles distinct from the panel's own glass in light appearance.
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
