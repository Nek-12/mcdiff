import AppKit
import McDiffCore

@MainActor
final class ComparisonWarningView: NSView {
    private let message = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 0
        message.setContentCompressionResistancePriority(.required, for: .vertical)
        Style.pin(message, in: self, inset: 10)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(snapshot: ReviewSnapshot?) {
        guard let snapshot, case .multipleMergeBases(let alternatives) = snapshot.warning else {
            isHidden = true
            message.stringValue = ""
            toolTip = nil
            return
        }
        message.stringValue = "Shared history is ambiguous — this comparison may include inherited changes."
        toolTip = """
        This follows the standard Git comparison.
        Merge the current target into this branch outside McDiff, then refresh.
        Selected merge base: \(snapshot.baseRevision)
        Other merge bases: \(alternatives.joined(separator: ", "))
        """
        isHidden = false
    }
}
