import AppKit

final class ReviewFooterView: NSView {
    static let minimumHeight: CGFloat = 120
    let message = Style.label("", size: 12, color: .secondaryLabelColor)
    let finishButton: NSButton
    var onFinishReview: (() -> Void)?

    override init(frame: NSRect) {
        finishButton = Style.button("Finish review", icon: .finish, target: nil, action: #selector(finishReview))
        super.init(frame: frame)
        finishButton.target = self
        finishButton.tintProminence = .primary
        finishButton.controlSize = .regular
        finishButton.borderShape = .capsule
        // Match the regular unified toolbar's capsule, not the 24-point dialog bezel.
        finishButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let stack = Style.stack([message, finishButton], orientation: .vertical, spacing: 12)
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(remainingFiles: Int, finishEnabled: Bool) {
        message.stringValue = remainingFiles == 0
            ? "0 files left to review. Well done!"
            : "\(remainingFiles) \(remainingFiles == 1 ? "file" : "files") left to review"
        finishButton.isEnabled = finishEnabled
    }

    @objc private func finishReview() { onFinishReview?() }
}
