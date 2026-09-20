import AppKit
import McDiffCore

enum DiffSearchTarget: Equatable {
    case path(file: Int)
    case code(file: Int, side: DiffSide, line: Int, importBlock: Int?)
    case markdown(file: Int, side: DiffSide)

    var file: Int {
        switch self {
        case .path(let file), .code(let file, _, _, _), .markdown(let file, _): return file
        }
    }
}

struct DiffSearchMatch: Equatable {
    let target: DiffSearchTarget
    let range: NSRange
}

struct DiffSearchResults {
    struct Group {
        let target: DiffSearchTarget
        let text: String
        let end: Int
    }
    let query: String
    let groups: [Group]
    let files: [Int]
    var count: Int { groups.last?.end ?? 0 }

    func match(at index: Int) throws -> DiffSearchMatch? {
        guard index >= 0, index < count else { return nil }
        var lower = 0, upper = groups.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if groups[middle].end <= index { lower = middle + 1 } else { upper = middle }
        }
        let group = groups[lower]
        let occurrence = index - (lower == 0 ? 0 : groups[lower - 1].end)
        var number = 0
        for range in LiteralSearch.matches(query, in: group.text) {
            try Task.checkCancellation()
            if number == occurrence { return DiffSearchMatch(target: group.target, range: range) }
            number += 1
        }
        return nil
    }
}

enum LiteralSearch {
    /// Foundation returns UTF-16 ranges, shared by Core Text and TextKit.
    /// Occurrences are streamed so a long repeated line cannot allocate millions
    /// of result objects. Navigation resolves just its selected occurrence.
    static func matches(_ query: String, in text: String, range: NSRange? = nil) -> AnySequence<NSRange> {
        let source = text as NSString
        let search = range ?? NSRange(location: 0, length: source.length)
        return AnySequence {
            var position = search.location
            return AnyIterator<NSRange> {
                guard !query.isEmpty, position < NSMaxRange(search) else { return nil }
                let found = source.range(of: query, options: .caseInsensitive,
                                         range: NSRange(location: position, length: NSMaxRange(search) - position))
                guard found.location != NSNotFound, found.length > 0 else { return nil }
                position = NSMaxRange(found)
                return found
            }
        }
    }
}

extension FileDiff {
    var headerTitle: String { oldPath == path ? path : "\(oldPath) → \(path)" }
}

actor DiffSearchEngine {
    func search(query: String, files: [FileDiff], presentations: [String: [PresentedRow]],
                markdown: [String: MarkdownFileContent], sourcePaths: Set<String>, layout: DiffLayout = .split) throws -> DiffSearchResults {
        var groups: [DiffSearchResults.Group] = []
        var matchingFiles: [Int] = []
        var count = 0
        func append(_ text: String, target: DiffSearchTarget) throws {
            let start = count
            for _ in LiteralSearch.matches(query, in: text) {
                try Task.checkCancellation()
                count += 1
            }
            guard count > start else { return }
            groups.append(.init(target: target, text: text, end: count))
            if matchingFiles.last != target.file { matchingFiles.append(target.file) }
        }
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            try append(file.headerTitle, target: .path(file: index))
            guard !file.isBinary else { continue }
            if RenderedMarkdown.accepts(file.path), !sourcePaths.contains(file.path) {
                if let content = markdown[file.path], content.error == nil {
                    for (side, source) in [(DiffSide.old, content.old), (.new, content.new)] {
                        if layout == .unified && side == .old { continue }
                        guard let source else { continue }
                        try Task.checkCancellation()
                        let text = RenderedMarkdown.text(source, color: .black, secondary: .gray).string
                        try append(text, target: .markdown(file: index, side: side))
                    }
                }
                continue
            }
            var code: [DiffPair] = []
            func appendPairs(_ pairs: [DiffPair], importBlock: Int?) throws {
                for row in DiffPresentation.sourceRows(pairs, layout: layout) {
                    let pair = row.pair
                    // Context is one occurrence in either layout.
                    if let line = pair.new, line.kind == .context, pair.old?.text == line.text,
                       let number = line.newNumber {
                        try append(line.text.replacingOccurrences(of: "\t", with: "    "),
                                   target: .code(file: index, side: .new, line: number, importBlock: importBlock))
                        continue
                    }
                    for (side, line) in [(DiffSide.old, pair.old), (.new, pair.new)] {
                        if let displayed = row.side, displayed != side { continue }
                        guard let line, let number = side == .old ? line.oldNumber : line.newNumber else { continue }
                        try append(line.text.replacingOccurrences(of: "\t", with: "    "),
                                   target: .code(file: index, side: side, line: number, importBlock: importBlock))
                    }
                }
            }
            func flush() throws {
                try appendPairs(code, importBlock: nil)
                code.removeAll(keepingCapacity: true)
            }
            for (block, presentation) in (presentations[file.path] ?? []).enumerated() {
                try Task.checkCancellation()
                switch presentation {
                case .hunk: try flush()
                case .code(let pair): code.append(pair)
                case .imports(let pairs):
                    try flush()
                    try appendPairs(pairs, importBlock: block)
                }
            }
            try flush()
        }
        return DiffSearchResults(query: query, groups: groups, files: matchingFiles)
    }

    func resolve(_ results: DiffSearchResults, at index: Int) throws -> DiffSearchMatch? {
        try results.match(at: index)
    }

    func index(of match: DiffSearchMatch, in results: DiffSearchResults) throws -> Int? {
        var start = 0
        for group in results.groups {
            try Task.checkCancellation()
            if group.target == match.target {
                for (offset, range) in LiteralSearch.matches(results.query, in: group.text).enumerated() {
                    try Task.checkCancellation()
                    if range == match.range { return start + offset }
                }
                return nil
            }
            start = group.end
        }
        return nil
    }
}
