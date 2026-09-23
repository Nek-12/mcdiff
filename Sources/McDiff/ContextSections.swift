import Foundation
import McDiffCore

/// Serializes source reads for one immutable comparison; full sources are temporary.
actor ContextSource {
    private let snapshot: ReviewSnapshot
    init(snapshot: ReviewSnapshot) { self.snapshot = snapshot }
    func presentation(file: FileDiff) throws -> [PresentedRow] {
        try Task.checkCancellation()
        let rows = try GitRepository(path: snapshot.request.repository).contextPresentation(snapshot: snapshot, file: file)
        try Task.checkCancellation()
        return rows
    }
    func lines(file: FileDiff, section: UnchangedSection) throws -> [DiffPair] {
        try Task.checkCancellation()
        let lines = try GitRepository(path: snapshot.request.repository)
            .unchangedLines(snapshot: snapshot, file: file, section: section)
        try Task.checkCancellation()
        return lines
    }
}

@MainActor
final class ContextSections {
    /// Only source locations are indexed; the presentation owns the text.
    struct AutomaticLines: Sendable {
        struct Location: Sendable { let row: Int; let pair: Int }
        let pages: [Int: [Location]]
        nonisolated init(file: FileDiff, rows: [PresentedRow]) {
            let patchNumbers = Set(file.hunks.flatMap(\.lines).compactMap(\.oldNumber))
            var pages: [Int: [Location]] = [:]
            func append(_ pair: DiffPair, row: Int, offset: Int) {
                guard let line = pair.old, line.kind == .context, let number = line.oldNumber,
                      !patchNumbers.contains(number) else { return }
                let linePages = Set([line.oldNumber, line.newNumber].compactMap { $0 }.map {
                    ($0 - 1) / SyntaxService.pageSize
                })
                for page in linePages { pages[page, default: []].append(Location(row: row, pair: offset)) }
            }
            for (index, row) in rows.enumerated() {
                switch row {
                case .code(let pair): append(pair, row: index, offset: 0)
                case .imports(let pairs):
                    for (offset, pair) in pairs.enumerated() { append(pair, row: index, offset: offset) }
                default: break
                }
            }
            self.pages = pages
        }
        func lines(page: Int, rows: [PresentedRow]) -> [DiffLine] {
            (pages[page] ?? []).compactMap { location in
                switch rows[location.row] {
                case .code(let pair): return pair.old
                case .imports(let pairs): return pairs[location.pair].old
                default:
                    assertionFailure("A context line must belong to a source row.")
                    NSLog("The context highlight index no longer matches the presentation.")
                    return nil
                }
            }
        }
    }
    enum Preparation {
        case loading(Task<Void, Never>)
        case ready(AutomaticLines)
        case failed(String)
    }
    enum State {
        case loading(Task<Void, Never>)
        case expanded([DiffPair])
        case empty
        case failed(String)
    }
    var load: ((FileDiff, UnchangedSection) async throws -> [DiffPair])?
    var resolve: ((FileDiff) async throws -> [PresentedRow])?
    var onChange: ((String, Int) -> Void)?
    var onResolved: ((String, [PresentedRow]?) -> Void)?
    private var entries: [String: [Int: State]] = [:]
    private var preparations: [String: Preparation] = [:]

    func state(path: String, section: Int) -> State? { entries[path]?[section] }
    func preparation(path: String) -> Preparation? { preparations[path] }

    func prepare(file: FileDiff, retry: Bool = false) {
        guard let resolve else { return }
        switch preparations[file.path] {
        case .loading, .ready: return
        case .failed where !retry: return
        default: break
        }
        guard !file.unchangedSections.isEmpty else { return }
        let task = Task { [weak self] in
            do {
                let rows = try await resolve(file)
                let index = await Task.detached { AutomaticLines(file: file, rows: rows) }.value
                guard !Task.isCancelled, let self else { return }
                self.preparations[file.path] = .ready(index)
                self.onResolved?(file.path, rows)
            } catch {
                guard !Task.isCancelled, let self else { return }
                NSLog("Could not resolve context for %@: %@", file.path, error.localizedDescription)
                self.preparations[file.path] = .failed(error.localizedDescription)
                self.onResolved?(file.path, nil)
            }
        }
        preparations[file.path] = .loading(task)
    }

    func clear() {
        for case .loading(let task) in preparations.values { task.cancel() }
        preparations.removeAll()
        for states in entries.values {
            for case .loading(let task) in states.values { task.cancel() }
        }
        entries.removeAll()
    }

    func toggle(file: FileDiff, section: UnchangedSection) {
        switch state(path: file.path, section: section.id) {
        case .loading, .empty: return
        case .expanded:
            entries[file.path]?[section.id] = nil
        case .failed, nil:
            let load = load
            let task = Task { [weak self] in
                do {
                    guard let load else { throw GitError("Context is unavailable. Reload the comparison.") }
                    let pairs = try await load(file, section)
                    guard !Task.isCancelled, let self else { return }
                    self.entries[file.path, default: [:]][section.id] = pairs.isEmpty ? .empty : .expanded(pairs)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    NSLog("Could not load context for %@: %@", file.path, error.localizedDescription)
                    self.entries[file.path, default: [:]][section.id] = .failed(error.localizedDescription)
                }
                self?.onChange?(file.path, section.id)
            }
            entries[file.path, default: [:]][section.id] = .loading(task)
        }
        onChange?(file.path, section.id)
    }

    var expandedPairs: [String: [Int: [DiffPair]]] {
        entries.compactMapValues { states in
            let pairs = states.compactMapValues { state -> [DiffPair]? in
                if case .expanded(let pairs) = state { return pairs }
                return nil
            }
            return pairs.isEmpty ? nil : pairs
        }
    }

    func pageLines(path: String, page: Int, presentation: [PresentedRow]) -> [DiffLine] {
        let pageStart = page * SyntaxService.pageSize + 1
        let pageEnd = pageStart + SyntaxService.pageSize
        var lines: [DiffLine] = []
        if case .ready(let index) = preparations[path] {
            lines = index.lines(page: page, rows: presentation)
        }
        for state in (entries[path] ?? [:]).values {
            guard case .expanded(let pairs) = state, let first = pairs.first else { continue }
            var offsets = IndexSet()
            for firstNumber in [first.old?.oldNumber, first.new?.newNumber].compactMap({ $0 }) {
                let start = max(0, pageStart - firstNumber)
                let end = min(pairs.count, pageEnd - firstNumber)
                if start < end { offsets.insert(integersIn: start..<end) }
            }
            lines += offsets.compactMap { pairs[$0].new ?? pairs[$0].old }
        }
        return lines.sorted { ($0.newNumber ?? $0.oldNumber!) < ($1.newNumber ?? $1.oldNumber!) }
    }
}
