import AppKit
import Markdown
import SlopdiffCore

struct MarkdownFileContent: Sendable {
    let old: String?
    let new: String?
    var error: String? = nil
}

/// No HTML interpreter, URL loader, attachments, or executable links are involved.
/// TextKit supplies native table layout; source HTML is displayed literally.
enum RenderedMarkdown {
    static func accepts(_ path: String) -> Bool {
        FileClassifier.markdownExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func text(_ source: String, color: NSColor, secondary: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 10
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: color, .paragraphStyle: paragraph
        ]
        return render(Document(parsing: source), attributes: attributes, secondary: secondary)
    }

    private static func render(_ node: Markup, attributes: [NSAttributedString.Key: Any],
                               secondary: NSColor) -> NSMutableAttributedString {
        var attrs = attributes
        let result = NSMutableAttributedString()
        func literal(_ value: String) -> NSMutableAttributedString {
            NSMutableAttributedString(string: value, attributes: attrs)
        }
        func children() {
            for child in node.children { result.append(render(child, attributes: attrs, secondary: secondary)) }
        }
        func paragraph() -> NSMutableParagraphStyle {
            (attrs[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        }
        func terminate() {
            if !result.string.hasSuffix("\n") { result.append(literal("\n")) }
        }
        switch node {
        case let text as Markdown.Text: return literal(text.string)
        case let code as InlineCode:
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            attrs[.backgroundColor] = secondary.withAlphaComponent(0.12)
            return literal(code.code)
        case let code as CodeBlock:
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            attrs[.backgroundColor] = secondary.withAlphaComponent(0.10)
            let style = paragraph()
            style.headIndent += 12; style.firstLineHeadIndent = style.headIndent
            style.lineBreakMode = .byCharWrapping
            attrs[.paragraphStyle] = style
            result.append(literal(code.code)); terminate()
        case let html as HTMLBlock:
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            result.append(literal(html.rawHTML)); terminate()
        case let html as InlineHTML: return literal(html.rawHTML)
        case is SoftBreak: return literal(" ")
        case is LineBreak: return literal("\u{2028}")
        case is ThematicBreak:
            attrs[.foregroundColor] = secondary
            return literal("────────────────────\n")
        case let heading as Heading:
            attrs[.font] = NSFont.systemFont(ofSize: CGFloat(max(15, 30 - heading.level * 3)), weight: .bold)
            let style = paragraph()
            style.paragraphSpacingBefore = 10; style.paragraphSpacing = 12
            attrs[.paragraphStyle] = style
            children(); terminate()
        case is Strong, is Emphasis:
            let font = attrs[.font] as! NSFont
            attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: node is Strong ? .boldFontMask : .italicFontMask)
            children()
        case is Strikethrough:
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            children()
        case is BlockQuote:
            let style = paragraph()
            style.headIndent += 18; style.firstLineHeadIndent = style.headIndent
            attrs[.paragraphStyle] = style; attrs[.foregroundColor] = secondary
            children(); terminate()
        case let list as OrderedList:
            appendList(node, start: Int(list.startIndex), attributes: attrs, secondary: secondary, to: result)
        case is UnorderedList:
            appendList(node, start: nil, attributes: attrs, secondary: secondary, to: result)
        case let table as Markdown.Table:
            let native = NSTextTable()
            native.numberOfColumns = table.maxColumnCount
            native.collapsesBorders = true
            native.layoutAlgorithm = .fixedLayoutAlgorithm
            native.setValue(100, type: .percentageValueType, for: .width)
            let rows: [[Markup]] = [Array(table.head.children)] + table.body.children.map { Array($0.children) }
            for (row, cells) in rows.enumerated() {
                for (column, cell) in cells.enumerated() {
                    let block = NSTextTableBlock(table: native, startingRow: row, rowSpan: 1,
                                                startingColumn: column, columnSpan: 1)
                    block.setWidth(6, type: .absoluteValueType, for: .padding)
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(secondary.withAlphaComponent(0.5))
                    if row == 0 { block.backgroundColor = secondary.withAlphaComponent(0.10) }
                    let style = paragraph()
                    style.textBlocks = [block]; style.paragraphSpacing = 0
                    switch table.columnAlignments[column] {
                    case .center: style.alignment = .center
                    case .right: style.alignment = .right
                    default: style.alignment = .left
                    }
                    var cellAttrs = attrs
                    cellAttrs[.paragraphStyle] = style
                    if row == 0 { cellAttrs[.font] = NSFont.systemFont(ofSize: 14, weight: .semibold) }
                    let value = render(cell, attributes: cellAttrs, secondary: secondary)
                    value.append(NSAttributedString(string: "\n", attributes: cellAttrs))
                    result.append(value)
                }
            }
            result.append(literal("\n"))
        case is Markdown.Image:
            attrs[.foregroundColor] = secondary
            result.append(literal("[Image: ")); children(); result.append(literal("]"))
        case is Paragraph:
            children(); terminate()
        default: children()
        }
        return result
    }

    private static func appendList(_ list: Markup, start: Int?, attributes: [NSAttributedString.Key: Any],
                                   secondary: NSColor, to result: NSMutableAttributedString) {
        for (index, child) in list.children.enumerated() {
            var attrs = attributes
            let style = (attrs[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            style.firstLineHeadIndent = style.headIndent
            style.headIndent += 24; style.paragraphSpacing = 4
            attrs[.paragraphStyle] = style
            let marker = (child as? ListItem)?.checkbox.map { $0 == .checked ? "☑" : "☐" }
                ?? start.map { "\($0 + index)." } ?? "•"
            result.append(NSAttributedString(string: "\(marker) ", attributes: attrs))
            result.append(render(child, attributes: attrs, secondary: secondary))
        }
    }
}

/// A layout is built on one worker and subsequently owned exclusively by the UI.
/// Only glyphs intersecting the visible rectangle are painted, even for long files.
final class MarkdownTextLayout {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container: NSTextContainer
    let height: CGFloat

    init(_ text: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(containerSize: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.backgroundLayoutEnabled = false
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        height = ceil(manager.usedRect(for: container).height)
    }

    func rect(for range: NSRange) -> NSRect {
        guard NSMaxRange(range) <= storage.length else { return .zero }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    func draw(at origin: NSPoint, visible: NSRect, search query: String = "", currentMatch: NSRange? = nil) {
        let local = visible.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = manager.glyphRange(forBoundingRect: local, in: container)
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        if !query.isEmpty {
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let margin = query.utf16.count
            let start = max(0, characters.location - margin)
            let end = min(storage.length, NSMaxRange(characters) + margin)
            for range in LiteralSearch.matches(query, in: storage.string, range: NSRange(location: start, length: end - start)) {
                NSColor.systemYellow.withAlphaComponent(range == currentMatch ? 0.70 : 0.35).setFill()
                let found = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                manager.enumerateEnclosingRects(forGlyphRange: found, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                in: container) { rect, _ in
                    rect.offsetBy(dx: origin.x, dy: origin.y).fill()
                }
            }
        }
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}

final class MarkdownPairLayout: NSObject {
    let old: MarkdownTextLayout
    let new: MarkdownTextLayout
    var height: CGFloat { max(44, max(old.height, new.height) + 36) }
    var cost: Int { (old.storage.length + new.storage.length) * 64 }

    init(content: MarkdownFileContent, width: CGFloat, color: NSColor, secondary: NSColor, mode: DiffLayout = .split) {
        old = MarkdownTextLayout(RenderedMarkdown.text(mode == .split ? content.old ?? "" : "", color: color, secondary: secondary), width: width)
        new = MarkdownTextLayout(RenderedMarkdown.text(content.new ?? "", color: color, secondary: secondary), width: width)
    }
}

actor MarkdownLayoutService {
    func layout(content: MarkdownFileContent, width: CGFloat, color: NSColor,
                secondary: NSColor, mode: DiffLayout = .split) throws -> MarkdownPairLayout {
        try Task.checkCancellation()
        let result = MarkdownPairLayout(content: content, width: width, color: color, secondary: secondary, mode: mode)
        try Task.checkCancellation()
        return result
    }
}
