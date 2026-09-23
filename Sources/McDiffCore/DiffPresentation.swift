import Foundation

public struct DiffPair: Sendable {
    public let old: DiffLine?
    public let new: DiffLine?
    public init(old: DiffLine?, new: DiffLine?) { self.old = old; self.new = new }
}

public enum PresentedRow: Sendable {
    case hunk(String)
    case code(DiffPair)
    case imports([DiffPair])
    case context(UnchangedSection)
}

public enum DiffPresentation {
    private static let importExtensions: Set<String> = [
        "kt", "kts", "java", "go", "ts", "tsx", "js", "jsx", "mjs", "cjs", "rs", "py", "pyi"
    ]

    /// Keeps the paired counterpart for word emphasis while ordering each
    /// contiguous edit as deletions followed by additions in a unified view.
    public static func sourceRows(_ pairs: [DiffPair], layout: DiffLayout) -> [(pair: DiffPair, side: DiffSide?)] {
        guard layout == .unified else { return pairs.map { ($0, nil) } }
        var result: [(pair: DiffPair, side: DiffSide?)] = []
        var changed: [DiffPair] = []
        func flush() {
            result += changed.filter { $0.old != nil }.map { ($0, .old) }
            result += changed.filter { $0.new != nil }.map { ($0, .new) }
            changed.removeAll(keepingCapacity: true)
        }
        for pair in pairs {
            if pair.new?.kind == .context || pair.old?.kind == .context {
                flush()
                result.append((pair, pair.new == nil ? .old : .new))
            } else {
                changed.append(pair)
            }
        }
        flush()
        return result
    }

    public static func rows(for file: FileDiff, oldSource: String? = nil, newSource: String? = nil,
                            resolveContext: Bool = false) -> [PresentedRow] {
        var result: [PresentedRow] = []
        let oldExtension = (file.oldPath as NSString).pathExtension.lowercased()
        let newExtension = (file.path as NSString).pathExtension.lowercased()
        let oldContext = oldSource.map { sourceImportNumbers($0, file: file, ext: oldExtension, side: .old) }
        let newContext = newSource.map { sourceImportNumbers($0, file: file, ext: newExtension, side: .new) }
        let sections = Dictionary(uniqueKeysWithValues: file.unchangedSections.map { ($0.beforeHunkIndex, $0) })
        let sourceLines = resolveContext ? oldSource?.components(separatedBy: "\n") : nil
        let sourceCount = sourceLines.map { $0.count - ($0.last == "" ? 1 : 0) } ?? 0
        var pendingImports: [DiffPair] = []
        func flushImports() {
            if !pendingImports.isEmpty {
                result.append(.imports(pendingImports))
                pendingImports.removeAll(keepingCapacity: true)
            }
        }
        func append(_ pair: DiffPair, oldImports: Set<Int>, newImports: Set<Int>) {
            let oldFold = pair.old == nil || pair.old?.oldNumber.map(oldImports.contains) == true
            let newFold = pair.new == nil || pair.new?.newNumber.map(newImports.contains) == true
            if oldFold && newFold { pendingImports.append(pair) }
            else { flushImports(); result.append(.code(pair)) }
        }
        func appendContext(before hunk: Int) {
            guard let section = sections[hunk] else { return }
            guard let sourceLines, let oldContext, let newContext else {
                flushImports()
                result.append(.context(section))
                return
            }
            let count = section.count ?? (sourceCount - section.oldStart)
            guard count > 0 else { return }
            func isImport(_ offset: Int) -> Bool {
                oldContext.contains(section.oldStart + offset + 1) &&
                    newContext.contains(section.newStart + offset + 1)
            }
            // Imports own their complete source runs, including omitted lines.
            // Only ordinary context is subject to the five-line disclosure rule.
            var start = 0
            while start < count {
                let imports = isImport(start)
                var end = start + 1
                while end < count && isImport(end) == imports { end += 1 }
                if !imports && end - start >= 5 {
                    flushImports()
                    result.append(.context(UnchangedSection(
                        beforeHunkIndex: section.beforeHunkIndex,
                        oldStart: section.oldStart + start, newStart: section.newStart + start,
                        count: section.count == nil && end == count ? nil : end - start)))
                } else {
                    for offset in start..<end {
                        let line = DiffLine(kind: .context, text: sourceLines[section.oldStart + offset],
                                            oldNumber: section.oldStart + offset + 1,
                                            newNumber: section.newStart + offset + 1)
                        append(DiffPair(old: line, new: line), oldImports: oldContext, newImports: newContext)
                    }
                }
                start = end
            }
        }
        for (index, hunk) in file.hunks.enumerated() {
            appendContext(before: index)
            if !resolveContext {
                flushImports()
                result.append(.hunk(hunk.header))
            }
            let oldLines = hunk.lines.filter { $0.kind != .addition }
            let newLines = hunk.lines.filter { $0.kind != .deletion }
            let oldImports = resolveContext ? oldContext ?? [] :
                includingWhitespace(oldContext ?? (sections.isEmpty ? importLineNumbers(oldLines, ext: oldExtension, side: .old) : []),
                                    lines: oldLines, side: .old)
            let newImports = resolveContext ? newContext ?? [] :
                includingWhitespace(newContext ?? (sections.isEmpty ? importLineNumbers(newLines, ext: newExtension, side: .new) : []),
                                    lines: newLines, side: .new)
            var pairs: [DiffPair] = [], i = 0
            while i < hunk.lines.count {
                let line = hunk.lines[i]
                if line.kind == .context {
                    pairs.append(DiffPair(old: line, new: line)); i += 1
                } else {
                    var old: [DiffLine] = [], new: [DiffLine] = []
                    while i < hunk.lines.count && hunk.lines[i].kind != .context {
                        if hunk.lines[i].kind == .deletion { old.append(hunk.lines[i]) }
                        else { new.append(hunk.lines[i]) }
                        i += 1
                    }
                    for n in 0..<max(old.count, new.count) {
                        pairs.append(DiffPair(old: n < old.count ? old[n] : nil, new: n < new.count ? new[n] : nil))
                    }
                }
            }
            for pair in pairs {
                append(pair, oldImports: oldImports, newImports: newImports)
            }
            if !resolveContext { flushImports() }
        }
        appendContext(before: file.hunks.count)
        flushImports()
        return result
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func includingWhitespace(_ imports: Set<Int>, lines: [DiffLine], side: DiffSide) -> Set<Int> {
        var result: Set<Int> = [], whitespace: [Int] = []
        var followsImport = false
        for line in lines {
            guard let number = side == .old ? line.oldNumber : line.newNumber else { continue }
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                if followsImport { whitespace.append(number) }
            } else if imports.contains(number) {
                result.insert(number)
                if followsImport { result.formUnion(whitespace) }
                followsImport = true
                whitespace.removeAll(keepingCapacity: true)
            } else {
                followsImport = false
                whitespace.removeAll(keepingCapacity: true)
            }
        }
        return result
    }

    private static func sourceImportNumbers(_ source: String, file: FileDiff, ext: String, side: DiffSide) -> Set<Int> {
        guard importExtensions.contains(ext) else { return [] }
        let texts = source.components(separatedBy: "\n")
        // The working file can change after Git produced the patch. Never fold
        // lines using source context from a different version of that file.
        guard file.hunks.flatMap(\.lines).allSatisfy({ line in
            guard let number = side == .old ? line.oldNumber : line.newNumber else { return true }
            return number > 0 && number <= texts.count && texts[number - 1] == line.text
        }) else { return [] }
        let lines = texts.enumerated().map {
            DiffLine(kind: .context, text: $0.element, oldNumber: $0.offset + 1, newNumber: $0.offset + 1)
        }
        // Scan from the start of the file so a hunk inside a string/comment
        // cannot masquerade as imports. Unsafe lines also separate import runs.
        var numbers: Set<Int> = [], segment: [DiffLine] = []
        var delimiter: String?
        var blockDepth = 0
        var quote: Character?
        var escaped = false
        for line in lines {
            var safe = delimiter == nil && quote == nil
            let text = line.text
            var index = text.startIndex
            while index < text.endIndex {
                let rest = text[index...], character = text[index]
                if let active = delimiter {
                    safe = false
                    if active == "*/" && rest.hasPrefix("/*") {
                        blockDepth += 1
                        index = text.index(index, offsetBy: 2)
                    } else if rest.hasPrefix(active) && !escaped {
                        if active == "*/" { blockDepth -= 1 }
                        if blockDepth == 0 { delimiter = nil }
                        index = text.index(index, offsetBy: active.count)
                    } else {
                        escaped = active != "*/" && !(active == "`" && ext == "go") && character == "\\" && !escaped
                        index = text.index(after: index)
                    }
                } else if let active = quote {
                    if character == active && !escaped { quote = nil }
                    escaped = character == "\\" && !escaped
                    index = text.index(after: index)
                } else if rest.hasPrefix("//") || (["py", "pyi"].contains(ext) && character == "#") {
                    safe = false
                    break
                } else if rest.hasPrefix("/*") {
                    safe = false; delimiter = "*/"; blockDepth = 1
                    index = text.index(index, offsetBy: 2)
                } else if rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''") || character == "`" {
                    safe = false
                    delimiter = character == "`" ? "`" : String(repeating: character, count: 3)
                    index = text.index(index, offsetBy: delimiter!.count)
                } else {
                    if character == "\"" || character == "'" { quote = character }
                    index = text.index(after: index)
                }
            }
            if quote != nil { safe = false }
            escaped = false
            if safe { segment.append(line) }
            else {
                numbers.formUnion(importLineNumbers(segment, ext: ext, side: side))
                segment.removeAll(keepingCapacity: true)
            }
        }
        numbers.formUnion(importLineNumbers(segment, ext: ext, side: side))
        return includingWhitespace(numbers, lines: lines, side: side)
    }

    private static func importLineNumbers(_ lines: [DiffLine], ext: String, side: DiffSide) -> Set<Int> {
        guard importExtensions.contains(ext) else { return [] }
        // Without full-file lexical state, multiline string/comment hunks are not
        // safe candidates for folding source-looking text.
        guard !lines.contains(where: { $0.text.contains("\"\"\"") || $0.text.contains("'''") || $0.text.contains("`") || $0.text.contains("/*") || $0.text.contains("*/") }) else { return [] }
        var numbers: Set<Int> = [], i = 0
        while i < lines.count {
            guard lines[i].text.utf16.count <= 32_768 else { i += 1; continue }
            var statement = lines[i].text.trimmingCharacters(in: .whitespaces)
            let start = i
            var end = i
            func complete(_ s: String) -> Bool {
                switch ext {
                case "kt", "kts":
                    return matches(s, #"^package\s+[\p{L}_][\p{L}\p{N}_]*(?:\.[\p{L}_][\p{L}\p{N}_]*)*;?$"#) ||
                        matches(s, #"^import [\p{L}_][\p{L}\p{N}_]*(?:\.[\p{L}\p{N}_]+)*(?:\.\*)?(?: as [\p{L}_][\p{L}\p{N}_]*)?;?$"#)
                case "java":
                    return matches(s, #"^package\s+[\p{L}_$][\p{L}\p{N}_$]*(?:\.[\p{L}_$][\p{L}\p{N}_$]*)*;$"#) ||
                        matches(s, #"^import (?:static )?[\p{L}_$][\p{L}\p{N}_$]*(?:\.[\p{L}\p{N}_$]+)*(?:\.\*)?;$"#)
                case "go":
                    return matches(s, #"^package\s+[\p{L}_][\p{L}\p{N}_]*;?$"#) ||
                        matches(s, #"^import\s+(?:(?:[\p{L}_][\p{L}\p{N}_]*|\.)\s+)?"[^"\n]+"\s*$"#) ||
                        matches(s, #"^import\s*\(\s*(?:(?:(?:[\p{L}_][\p{L}\p{N}_]*|\.)\s+)?"[^"\n]+"\s*)+\)$"#)
                case "py", "pyi":
                    let names = #"[\p{L}_][\p{L}\p{N}_]*(?:\.[\p{L}_][\p{L}\p{N}_]*)*(?:\s+as\s+[\p{L}_][\p{L}\p{N}_]*)?"#
                    return matches(s, "^import\\s+\(names)(?:\\s*,\\s*\(names))*\\s*$") ||
                        matches(s, "^from\\s+[\\p{L}\\p{N}_.]+\\s+import\\s+(?:\\*|\(names)(?:\\s*,\\s*\(names))*|\\(\\s*\(names)(?:\\s*,\\s*\(names))*\\s*,?\\s*\\))\\s*$")
                case "rs":
                    return matches(s, #"^(?:pub(?:\([^)]*\))?\s+)?use\s+[\p{L}\p{N}_:\s{},*]+;$"#) && balanced(s)
                default:
                    return matches(s, #"^import\s+(?:(?:type\s+)?[\p{L}\p{N}_$*,{}\s]+\s+from\s+)?(?:"[^"\n]+"|'[^'\n]+')\s*;?$"#) && balanced(s)
                }
            }
            let prefix = statement.hasPrefix("import ") || statement == "import(" || statement == "import (" ||
                (["kt", "kts", "java", "go"].contains(ext) && matches(statement, #"^package\s"#)) ||
                (["py", "pyi"].contains(ext) && statement.hasPrefix("from ")) ||
                (ext == "rs" && (statement.hasPrefix("use ") || statement.hasPrefix("pub use ") || statement.hasPrefix("pub(")))
            if prefix {
                // Only continue a statement that explicitly opens an import list.
                if !complete(statement) && (statement.contains("{") || statement.contains("(")) {
                    while end + 1 < lines.count && end - start < 200 && statement.count < 32_768 {
                        let next = lines[end + 1].text.trimmingCharacters(in: .whitespaces)
                        guard next.utf16.count <= 32_768,
                              !next.contains("//"), !next.contains("#"),
                              !next.contains("="), !next.contains(";") || next.hasSuffix(";") else { break }
                        end += 1; statement += "\n" + next
                        if complete(statement) { break }
                        if balanced(statement) { break }
                    }
                }
                if complete(statement) {
                    for line in lines[start...end] {
                        if let number = side == .old ? line.oldNumber : line.newNumber { numbers.insert(number) }
                    }
                    i = end + 1; continue
                }
            }
            i += 1
        }
        return numbers
    }

    private static func balanced(_ text: String) -> Bool {
        var stack: [Character] = []
        var quote: Character?
        for c in text {
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "{" || c == "(" { stack.append(c) }
            if c == "}" || c == ")" {
                guard stack.popLast() == (c == "}" ? "{" : "(") else { return false }
            }
        }
        return stack.isEmpty && quote == nil
    }
}

public enum WordDiff {
    private static let tokenPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}\p{M}_$]+|\s+|[=<>!&|+\-*/%^~?:]+|[^\p{L}\p{N}\p{M}_$\s]"#)

    private struct Token {
        let text: String
        let range: NSRange
    }

    public static func ranges(old: String, new: String) -> (old: [NSRange], new: [NSRange]) {
        if old == new { return ([], []) }
        // A minified line is one bounded render unit, not a quadratic token matrix.
        guard old.utf16.count <= 16_384, new.utf16.count <= 16_384 else {
            return (old.isEmpty ? [] : [NSRange(location: 0, length: old.utf16.count)],
                    new.isEmpty ? [] : [NSRange(location: 0, length: new.utf16.count)])
        }
        let a = tokenize(old), b = tokenize(new)
        guard a.count <= 512, b.count <= 512 else {
            return (old.isEmpty ? [] : [NSRange(location: 0, length: old.utf16.count)],
                    new.isEmpty ? [] : [NSRange(location: 0, length: new.utf16.count)])
        }
        let width = b.count + 1
        var table = [Int](repeating: 0, count: (a.count + 1) * width)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i * width + j] = a[i].text == b[j].text
                        ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }
        var left: [NSRange] = [], right: [NSRange] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && j < b.count && a[i].text == b[j].text { i += 1; j += 1 }
            else if i < a.count && (j == b.count || table[(i + 1) * width + j] >= table[i * width + j + 1]) {
                left.append(a[i].range); i += 1
            } else { right.append(b[j].range); j += 1 }
        }
        return (left, right)
    }

    private static func tokenize(_ text: String) -> [Token] {
        // NSString ranges match AppKit's UTF-16 attributed-string coordinates.
        let ns = text as NSString
        return tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            Token(text: ns.substring(with: $0.range), range: $0.range)
        }
    }
}
