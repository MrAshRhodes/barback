import AppKit

/// A native, keyboard-operable horizontal strip. Icons come from applications, never screen capture.
@MainActor
final class NotchOverflowWindow: NSPanel {
    private static let tileWidth: CGFloat = 96
    private static let tileGap: CGFloat = 8
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let document = NSView()
    private let previous = NSButton(title: String(localized: "Previous"), target: nil, action: nil)
    private let next = NSButton(title: String(localized: "Next"), target: nil, action: nil)
    private let refresh = NSButton()
    private var itemButtons: [NSButton] = []
    private var items: [DropDownPanelItem] = []
    private var boundsObserver: NSObjectProtocol?
    private let reduceMotion: @MainActor () -> Bool

    var onClose: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onOpen: (DropDownPanelItem) -> Void = { _ in }

    var horizontalOffset: CGFloat { scrollView.documentVisibleRect.minX }
    var canPageNext: Bool { next.isEnabled }
    var canPagePrevious: Bool { previous.isEnabled }
    var displayedTitles: [String] { itemButtons.map(\.title) }

    init(reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        title = String(localized: "Notch overflow")
        setAccessibilityLabel(title)
        setAccessibilitySubrole(.dialog)
        buildContent()
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onClose() }

    override func keyDown(with event: NSEvent) {
        if !handlePagingKey(event) { super.keyDown(with: event) }
    }

    func handlePagingKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 53: onClose()
        case 123, 116: page(by: -1, keyboard: true)
        case 124, 121: page(by: 1, keyboard: true)
        case 115: scroll(to: 0, keyboard: true)
        case 119: scroll(to: document.frame.width, keyboard: true)
        default: return false
        }
        return true
    }

    func update(items: [DropDownPanelItem], title: String, status: String, canOpen: Bool, refreshing: Bool) {
        titleLabel.stringValue = String(localized: "Notch overflow — \(title)")
        statusLabel.stringValue = status
        statusLabel.toolTip = status
        statusLabel.setAccessibilityLabel(status)
        refresh.isEnabled = !refreshing
        let changed = self.items.map(\.id) != items.map(\.id) || self.items.map(\.title) != items.map(\.title)
        self.items = items
        if changed {
            itemButtons.forEach { $0.removeFromSuperview() }
            itemButtons = items.enumerated().map { index, item in
                let button = NSButton(title: item.title, target: self, action: #selector(openClicked(_:)))
                button.tag = index
                button.bezelStyle = .regularSquare
                button.imagePosition = .imageAbove
                button.imageScaling = .scaleProportionallyDown
                let icon = item.icon?.copy() as? NSImage
                    ?? NSImage(systemSymbolName: item.fallbackSymbol, accessibilityDescription: nil)
                icon?.size = NSSize(width: 28, height: 28)
                button.image = icon
                button.font = .systemFont(ofSize: 11)
                button.cell?.lineBreakMode = .byTruncatingTail
                button.toolTip = item.subtitle.map { "\(item.title) — \($0)" } ?? item.title
                button.setAccessibilityLabel(String(localized: "Open \(item.title)"))
                button.setAccessibilityHelp(String(localized: "Opens this identified menu bar item with Accessibility."))
                button.frame = NSRect(
                    x: CGFloat(index) * (Self.tileWidth + Self.tileGap), y: 0,
                    width: Self.tileWidth, height: 72
                )
                document.addSubview(button)
                return button
            }
            document.setFrameSize(NSSize(
                width: max(0, CGFloat(items.count) * (Self.tileWidth + Self.tileGap) - Self.tileGap), height: 72
            ))
        }
        for button in itemButtons { button.isEnabled = canOpen }
        contentView?.layoutSubtreeIfNeeded()
        if changed {
            scrollView.contentView.scroll(to: NSPoint(x: min(horizontalOffset, maximumOffset), y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updatePagingControls()
    }

    func page(by direction: Int, keyboard: Bool = false) {
        let stride = max(Self.tileWidth + Self.tileGap, scrollView.contentSize.width - Self.tileGap)
        scroll(to: horizontalOffset + CGFloat(direction) * stride, keyboard: keyboard)
    }

    private var maximumOffset: CGFloat { max(0, document.frame.width - scrollView.contentSize.width) }

    private func scroll(to proposed: CGFloat, keyboard: Bool) {
        let x = min(maximumOffset, max(0, proposed))
        if reduceMotion() {
            scrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
            }
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if keyboard, !itemButtons.isEmpty {
            let index = min(itemButtons.count - 1, max(0, Int(ceil(x / (Self.tileWidth + Self.tileGap)))))
            if itemButtons[index].isEnabled { makeFirstResponder(itemButtons[index]) }
        }
        updatePagingControls()
    }

    private func updatePagingControls() {
        previous.isEnabled = horizontalOffset > 0.5
        next.isEnabled = horizontalOffset < maximumOffset - 0.5
    }

    private func buildContent() {
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.state = .active
        backdrop.blendingMode = .behindWindow
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.masksToBounds = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            backdrop.blendingMode = .withinWindow
            backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            backdrop.layer?.borderWidth = 1
            backdrop.layer?.borderColor = NSColor.labelColor.cgColor
        }
        contentView = backdrop
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -12),
        ])

        titleLabel.font = .boldSystemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!, target: self, action: #selector(closeClicked))
        close.bezelStyle = .inline
        close.setAccessibilityLabel(String(localized: "Close notch overflow"))
        close.toolTip = String(localized: "Close (Escape)")
        let header = NSStackView(views: [titleLabel, close])
        header.orientation = .horizontal
        header.distribution = .fill
        stack.addArrangedSubview(header)

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = document
        scrollView.setAccessibilityLabel(String(localized: "Identified items on this display"))
        scrollView.setAccessibilityHelp(String(localized: "Scroll horizontally or use Previous, Next, Left Arrow, Right Arrow, Page Up or Page Down."))
        stack.addArrangedSubview(scrollView)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(statusLabel)

        previous.target = self
        previous.action = #selector(previousClicked)
        previous.bezelStyle = .rounded
        previous.toolTip = String(localized: "Previous page (Left Arrow or Page Up)")
        previous.setAccessibilityLabel(String(localized: "Previous page of menu bar items"))
        next.target = self
        next.action = #selector(nextClicked)
        next.bezelStyle = .rounded
        next.toolTip = String(localized: "Next page (Right Arrow or Page Down)")
        next.setAccessibilityLabel(String(localized: "Next page of menu bar items"))
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.target = self
        refresh.action = #selector(refreshClicked)
        refresh.bezelStyle = .rounded
        refresh.setAccessibilityLabel(String(localized: "Refresh notch overflow items"))
        refresh.toolTip = String(localized: "Refresh items")
        let controls = NSStackView(views: [previous, next, refresh])
        controls.orientation = .horizontal
        controls.distribution = .fillProportionally
        controls.spacing = 4
        stack.addArrangedSubview(controls)
        for view in [header, scrollView, statusLabel, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 24),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
            controls.heightAnchor.constraint(equalToConstant: 40),
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePagingControls() }
        }
    }

    @objc private func openClicked(_ sender: NSButton) {
        guard sender.isEnabled, items.indices.contains(sender.tag) else { return }
        onOpen(items[sender.tag])
    }
    @objc private func previousClicked() { page(by: -1) }
    @objc private func nextClicked() { page(by: 1) }
    @objc private func refreshClicked() { onRefresh() }
    @objc private func closeClicked() { onClose() }
}
