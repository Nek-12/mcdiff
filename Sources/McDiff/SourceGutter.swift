import AppKit
import McDiffCore

/// Line identities and comments belong to a side; the change sign belongs to the row.
struct SourceGutter {
    let layout: DiffLayout
    static let numberColumnWidth: CGFloat = 44
    static let numberTrailing: CGFloat = 47
    static let commentLeading: CGFloat = 4
    static let commentWidth: CGFloat = 18

    func columnOffset(_ side: DiffSide) -> CGFloat {
        layout == .unified && side == .new ? Self.numberColumnWidth : 0
    }

    var changeLeading: CGFloat {
        Self.numberTrailing + (layout == .unified ? Self.numberColumnWidth : 0) + 6
    }
    var textLeading: CGFloat { changeLeading + 19 }

    func commentLeading(_ side: DiffSide) -> CGFloat {
        columnOffset(side) + Self.commentLeading
    }
}
