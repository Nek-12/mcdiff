import Foundation
import McDiffCore

/// Serializes source reads for one immutable comparison; full sources are temporary.
actor ContextSource {
    private let snapshot: ReviewSnapshot
    init(snapshot: ReviewSnapshot) { self.snapshot = snapshot }
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
    enum State {
        case loading(Task<Void, Never>)
        case expanded([DiffPair])
        case empty
        case failed(String)
    }
    var load: ((FileDiff, UnchangedSection) async throws -> [DiffPair])?
    var onChange: ((String, Int) -> Void)?
    private var entries: [String: [Int: State]] = [:]

    func state(path: String, section: Int) -> State? { entries[path]?[section] }

    func clear() {
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

    func pageLines(path: String, page: Int) -> [DiffLine] {
        let pageStart = page * SyntaxService.pageSize + 1
        let pageEnd = pageStart + SyntaxService.pageSize
        guard let states = entries[path] else { return [] }
        var lines: [DiffLine] = []
        for state in states.values {
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
