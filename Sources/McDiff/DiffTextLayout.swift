import AppKit
import CoreText

/// Measurement and painting share Core Text's UTF-16 breakpoints.
enum DiffTextLayout {
    final class Breaks: NSObject {
        let ranges: [NSRange]
        init(_ ranges: [NSRange]) { self.ranges = ranges }
    }
    static func ranges(_ text: NSAttributedString, width: CGFloat?) -> [NSRange] {
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }
        guard let width else { return [NSRange(location: 0, length: text.length)] }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        let string = text.string as NSString
        var result: [NSRange] = [], start = 0
        while start < text.length {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width)))
            // At extremely narrow widths consume a whole grapheme, never half a surrogate.
            let count = suggested > 0 ? suggested : string.rangeOfComposedCharacterSequence(at: start).length
            result.append(NSRange(location: start, length: count))
            start += count
        }
        return result
    }

    static func width(_ text: NSAttributedString) -> CGFloat {
        let line = CTLineCreateWithAttributedString(text)
        let glyphs = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        return ceil(max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), glyphs.maxX))
    }
}
