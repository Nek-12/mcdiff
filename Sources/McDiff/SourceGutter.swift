import AppKit
import McDiffCore

/// Compact number columns without a reserved leading comment slot.
struct SourceGutter {
    let layout: DiffLayout
    var numberWidth: CGFloat = 18
    static let columnGap: CGFloat = 13
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    static func numberWidth(for number: Int) -> CGFloat {
        ceil(("\(number)" as NSString).size(withAttributes: [.font: numberFont]).width)
    }

    var numberTrailing: CGFloat { numberWidth }

    func columnOffset(_ side: DiffSide) -> CGFloat {
        layout == .unified && side == .new ? numberWidth + Self.columnGap : 0
    }

    var changeLeading: CGFloat {
        numberTrailing + columnOffset(.new) + 6
    }
    var textLeading: CGFloat { changeLeading + 19 }
}
