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

    /// Single-line import grammars permit cheap rejection before reading blobs.
    /// This is only a prefilter: quoted fragments still need full-source validation.
    static func mayBeWhitespaceAndImportsOnly(_ file: FileDiff) -> Bool {
        let ext = (file.path as NSString).pathExtension.lowercased()
        if importExtensions.contains(ext) && !["kt", "kts", "java"].contains(ext) { return true }
        func significant(_ lines: [DiffLine], side: DiffSide) -> String {
            lines.filter { importLineNumbers([$0], ext: ext, side: side).isEmpty }
                .map { $0.text.filter { !$0.isWhitespace } }.joined()
        }
        return file.hunks.allSatisfy { hunk in
            let old = hunk.lines.filter { $0.kind == .deletion }
            let new = hunk.lines.filter { $0.kind == .addition }
            let whitespaceOnly = old.map { $0.text.filter { !$0.isWhitespace } }.joined() ==
                new.map { $0.text.filter { !$0.isWhitespace } }.joined()
            return whitespaceOnly || significant(old, side: .old) == significant(new, side: .new)
        }
    }

    static func mayHaveWhitespaceLines(_ file: FileDiff) -> Bool {
        for hunk in file.hunks {
            var old: [String: String] = [:]
            for line in hunk.lines where line.kind == .deletion {
                let key = line.text.filter { !$0.isWhitespace }
                if key.isEmpty { return true }
                if let previous = old[key], !previous.utf8.elementsEqual(line.text.utf8) { return true }
                old[key] = line.text
            }
            for line in hunk.lines where line.kind == .addition {
                let key = line.text.filter { !$0.isWhitespace }
                if key.isEmpty { return true }
                if let previous = old[key], !previous.utf8.elementsEqual(line.text.utf8) { return true }
            }
        }
        return false
    }

    /// Presentation-only projection. Raw lines, side texts, counts and review
    /// identity stay unchanged; neutral counterparts share both original numbers.
    public static func ignoringWhitespace(in pairs: [DiffPair], file: FileDiff) -> [DiffPair] {
        guard !file.whitespaceChanges.isEmpty else { return pairs }
        let matches = file.whitespaceChanges.pairsByOld
        let blankOld = file.whitespaceChanges.oldBlankLines
        let blankNew = file.whitespaceChanges.newBlankLines
        let pairedNew = file.whitespaceChanges.pairedNewLines
        var result: [DiffPair] = []
        func neutral(_ old: DiffLine?, _ new: DiffLine?) -> DiffPair {
            let oldNumber = old?.oldNumber, newNumber = new?.newNumber
            return DiffPair(
                old: old.map { .init(kind: .context, text: $0.text, oldNumber: oldNumber, newNumber: newNumber) },
                new: new.map { .init(kind: .context, text: $0.text, oldNumber: oldNumber, newNumber: newNumber) })
        }
        func project() {
            let old = pairs.compactMap(\.old), new = pairs.compactMap(\.new)
            let newIndices = Dictionary(uniqueKeysWithValues: new.enumerated().compactMap { index, line -> (Int, Int)? in
                line.newNumber.map { ($0, index) }
            })
            let anchors = old.enumerated().compactMap { index, line -> (old: Int, new: Int)? in
                guard let oldNumber = line.oldNumber else { return nil }
                let newNumber: Int?
                if let matched = matches[oldNumber] {
                    newNumber = matched
                } else if line.kind == .context, !blankOld.contains(oldNumber),
                          let counterpart = line.newNumber, !pairedNew.contains(counterpart), !blankNew.contains(counterpart) {
                    newNumber = counterpart
                } else {
                    newNumber = nil
                }
                guard let newNumber, let newIndex = newIndices[newNumber] else { return nil }
                return (index, newIndex)
            }
            var oldIndex = 0, newIndex = 0
            for anchor in anchors + [(old.count, new.count)] {
                while oldIndex < anchor.old || newIndex < anchor.new {
                    let lhs = oldIndex < anchor.old ? old[oldIndex] : nil
                    let rhs = newIndex < anchor.new ? new[newIndex] : nil
                    let leftBlank = lhs?.oldNumber.map(blankOld.contains) == true
                    let rightBlank = rhs?.newNumber.map(blankNew.contains) == true
                    if leftBlank || rightBlank {
                        result.append(neutral(leftBlank ? lhs : nil, rightBlank ? rhs : nil))
                        if leftBlank { oldIndex += 1 }
                        if rightBlank { newIndex += 1 }
                    } else {
                        result.append(DiffPair(old: lhs, new: rhs))
                        if lhs != nil { oldIndex += 1 }
                        if rhs != nil { newIndex += 1 }
                    }
                }
                if anchor.old < old.count && anchor.new < new.count {
                    result.append(neutral(old[anchor.old], new[anchor.new]))
                }
                oldIndex = anchor.old + 1; newIndex = anchor.new + 1
            }
        }
        project()
        return result
    }

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
        let scan = SourceLexing(source, ext: ext)
        let texts = scan.lines
        // The working file can change after Git produced the patch. Never fold
        // lines using source context from a different version of that file.
        guard file.hunks.flatMap(\.lines).allSatisfy({ line in
            guard let number = side == .old ? line.oldNumber : line.newNumber else { return true }
            return number > 0 && number <= texts.count && texts[number - 1] == line.text
        }) else { return [] }
        return sourceImportNumbers(scan, ext: ext, side: side)
    }

    static func sourceImportNumbers(_ scan: SourceLexing, ext: String, side: DiffSide = .new) -> Set<Int> {
        guard importExtensions.contains(ext) else { return [] }
        let lines = scan.lines.enumerated().map {
            DiffLine(kind: .context, text: $0.element, oldNumber: $0.offset + 1, newNumber: $0.offset + 1)
        }
        // Scan from the start of the file so a hunk inside a string/comment
        // cannot masquerade as imports. Unsafe lines also separate import runs.
        var numbers: Set<Int> = [], segment: [DiffLine] = []
        for (index, line) in lines.enumerated() {
            if scan.importSafe[index] { segment.append(line) }
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
                        matches(s, #"^import\s+[\p{L}_][\p{L}\p{N}_]*(?:\.[\p{L}\p{N}_]+)*(?:\.\*)?(?:\s+as\s+[\p{L}_][\p{L}\p{N}_]*)?;?$"#)
                case "java":
                    return matches(s, #"^package\s+[\p{L}_$][\p{L}\p{N}_$]*(?:\.[\p{L}_$][\p{L}\p{N}_$]*)*;$"#) ||
                        matches(s, #"^import\s+(?:static\s+)?[\p{L}_$][\p{L}\p{N}_$]*(?:\.[\p{L}\p{N}_$]+)*(?:\.\*)?;$"#)
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
            let prefix = (statement.hasPrefix("import") && matches(statement, #"^import(?:\s|\()"#)) ||
                (["kt", "kts", "java", "go"].contains(ext) && statement.hasPrefix("package") && matches(statement, #"^package\s"#)) ||
                (["py", "pyi"].contains(ext) && statement.hasPrefix("from") && matches(statement, #"^from\s"#)) ||
                (ext == "rs" && (statement.hasPrefix("use") || statement.hasPrefix("pub")))
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
