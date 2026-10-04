import AppKit

enum Style {
    static let codeFont = NSFont(name: "MonaspaceNeon-Regular", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let smallFont = NSFont.systemFont(ofSize: 11)
    static let rowHeight: CGFloat = 22
    static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static var canvas: NSColor { .clear }
    static var added: NSColor { NSColor.systemGreen.withAlphaComponent(dark ? 0.105 : 0.08) }
    static var removed: NSColor { NSColor.systemRed.withAlphaComponent(dark ? 0.10 : 0.07) }
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }
    static func button(_ title: String, icon: Icons.Symbol? = nil, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .glass
        button.toolTip = title.isEmpty ? nil : title
        if let icon { button.image = Icons.image(icon); button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
        return button
    }
    static func animateStateChange(_ view: NSView?) {
        guard let view, view.window?.isVisible == true else { return }
        view.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.16
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer?.add(transition, forKey: "stateChange")
    }
    static func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .horizontal, spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation; stack.spacing = spacing; stack.alignment = orientation == .horizontal ? .centerY : .leading
        return stack
    }
    static func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}

enum Icons {
    enum Symbol: String, CaseIterable {
        case home = "house"
        case refresh = "arrow.clockwise"
        case account = "person.crop.circle"
        case folder = "folder"
        case recents = "clock.arrow.circlepath"
        case comment = "bubble"
        case next = "arrow.down"
        case previous = "arrow.up"
        case review = "checkmark"
        case finish = "checkmark.circle"
        case wrap = "arrow.turn.down.left"
        case unified = "rectangle"
        case split = "rectangle.split.2x1"
        case search = "magnifyingglass"
        case close = "xmark"
        case copy = "doc.on.doc"
        case export = "square.and.arrow.down"
        case compare = "arrow.left.arrow.right"
        case pullRequest = "arrow.triangle.pull"
        case chevronDown = "chevron.down"
        case chevronRight = "chevron.right"
        case delete = "trash"
        case link = "link"
        case document = "doc.text"
    }

    static let toolbarPointSize: CGFloat = 16
    private static let configuration = NSImage.SymbolConfiguration(pointSize: toolbarPointSize, weight: .regular, scale: .medium)
    private static var cache: [Symbol: NSImage] = [:]

    static func configureSearchField(_ field: NSSearchField) {
        guard let cell = field.cell as? NSSearchFieldCell else {
            assertionFailure("Search field must use NSSearchFieldCell")
            NSLog("McDiff: Search field must use NSSearchFieldCell")
            return
        }
        cell.searchButtonCell?.image = image(.search)
    }

    static func draw(_ symbol: Symbol, in rect: NSRect, color: NSColor = .secondaryLabelColor) {
        guard let colored = image(symbol).withSymbolConfiguration(.init(paletteColors: [color])) else {
            assertionFailure("Could not color SF Symbol \(symbol.rawValue)")
            NSLog("McDiff: Could not color SF Symbol %@", symbol.rawValue)
            return
        }
        colored.isTemplate = false
        let size = colored.size
        let scale = min(rect.width / size.width, rect.height / size.height)
        let target = NSRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
                            width: size.width * scale, height: size.height * scale)
        colored.draw(in: target)
    }

    static func image(_ symbol: Symbol) -> NSImage {
        if let value = cache[symbol] { return value }
        guard let source = NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil),
              let configured = source.withSymbolConfiguration(configuration) else {
            assertionFailure("Unavailable SF Symbol \(symbol.rawValue)")
            NSLog("McDiff: Unavailable SF Symbol %@", symbol.rawValue)
            return NSImage()
        }
        configured.isTemplate = true
        cache[symbol] = configured
        return configured
    }
}

final class AnimatedCheckbox: NSButton {
    func configureReview(reviewed: Bool, reason: String?) {
        state = reviewed ? .on : .off
        isEnabled = reason == nil
        toolTip = reason.map { "Automatically reviewed: \($0). Change the corresponding global filter to review manually." }
            ?? (reviewed ? "Mark file as unreviewed and expand" : "Mark file as reviewed and collapse")
    }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        let sent = super.sendAction(action, to: target)
        Style.animateStateChange(self)
        return sent
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A layer mask softens the scroll boundary without placing a painted overlay on glass.
final class FadingScrollView: NSScrollView {
    private let fade = CAGradientLayer()
    var topFadeHeight: CGFloat = 16 {
        didSet { if topFadeHeight != oldValue { updateFade() } }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = NSScroller.preferredScrollerStyle
        autohidesScrollers = true
        wantsLayer = true
        layer?.mask = fade
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        updateFade()
    }
    private func updateFade() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.startPoint = CGPoint(x: 0.5, y: isFlipped ? 0 : 1)
        fade.endPoint = CGPoint(x: 0.5, y: isFlipped ? 1 : 0)
        let height = max(1, bounds.height)
        let bottom = max(0.5, 1 - 16 / height)
        let top = min(bottom, max(0, topFadeHeight / height))
        fade.colors = [(top > 0 ? NSColor.clear : .black).cgColor,
                       NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, top, bottom, 1].map { NSNumber(value: Double($0)) }
        CATransaction.commit()
    }
}
