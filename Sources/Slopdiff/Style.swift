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
    static func button(_ title: String, icon: String? = nil, target: AnyObject?, action: Selector) -> NSButton {
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
    private struct TintKey: Hashable {
        let name: String
        let dark: Bool
        let color: NSColor
    }
    private static var cache: [String: NSImage] = [:]
    private static var tinted: [TintKey: NSImage] = [:]
    static func toolbarImage(_ name: String) -> NSImage? {
        guard let image = (image(name) ?? NSImage(systemSymbolName: name, accessibilityDescription: nil))?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 20, height: 20)
        return image
    }
    static func draw(_ name: String, in rect: NSRect, color: NSColor = .secondaryLabelColor) {
        let key = TintKey(name: name, dark: Style.dark, color: color)
        if tinted[key] == nil, let original = image(name) {
            tinted[key] = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
                original.draw(in: bounds)
                color.setFill()
                bounds.fill(using: .sourceAtop)
                return true
            }
        }
        tinted[key]?.draw(in: rect)
    }
    static func image(_ name: String) -> NSImage? {
        if let value = cache[name] { return value }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources/Lucide"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

final class AnimatedCheckbox: NSButton {
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
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = .overlay
        autohidesScrollers = true
        wantsLayer = true
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.mask = fade
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = bounds
        let edge = min(0.5, 16 / max(1, bounds.height))
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        CATransaction.commit()
    }
}
