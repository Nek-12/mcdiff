import Foundation
import McDiffCore

struct SourceTextPosition: Comparable {
    let line: Int
    let offset: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line ? lhs.offset < rhs.offset : lhs.line < rhs.line
    }
}

struct SourceTextSelection {
    let file: Int
    let side: DiffSide
    let anchor: SourceTextPosition
    let head: SourceTextPosition

    var start: SourceTextPosition { min(anchor, head) }
    var end: SourceTextPosition { max(anchor, head) }

    func range(line: Int, text: String) -> NSRange? {
        guard (start.line...end.line).contains(line), start != end else { return nil }
        let length = (text as NSString).length
        let lower = line == start.line ? min(length, start.offset) : 0
        let upper = line == end.line ? min(length, end.offset) : length
        return NSRange(location: lower, length: max(0, upper - lower))
    }
}

/// CoreText sees four spaces for a source tab; selections retain original offsets.
enum SourceTextOffsets {
    static func displayOffset(_ offset: Int, in text: String) -> Int {
        text.utf16.prefix(offset).reduce(0) { $0 + ($1 == 9 ? 4 : 1) }
    }

    static func sourceOffset(_ offset: Int, in text: String) -> Int {
        var display = 0
        let source = text as NSString
        for (index, unit) in text.utf16.enumerated() {
            let width = unit == 9 ? 4 : 1
            if offset < display + width {
                if unit == 9 { return offset - display < 2 ? index : index + 1 }
                let character = source.rangeOfComposedCharacterSequence(at: index)
                return (index - character.location) * 2 < character.length ? character.location : NSMaxRange(character)
            }
            display += width
        }
        return source.length
    }
}
