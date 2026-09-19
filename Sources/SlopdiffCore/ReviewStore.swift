import Foundation
import CryptoKit

public enum DiffLayout: String, Codable, Sendable {
    case split, unified
}

public struct ReviewPreferences: Codable, Sendable {
    public var filters: ReviewFilters
    public var repositoryMappings: [String: String]
    public var recentComparisons: [ComparisonRequest]
    public var softWrap: Bool
    public var diffLayout: DiffLayout
    public init(filters: ReviewFilters = .init(), repositoryMappings: [String: String] = [:],
                recentComparisons: [ComparisonRequest] = [], softWrap: Bool = false, diffLayout: DiffLayout = .split) {
        self.filters = filters
        self.repositoryMappings = repositoryMappings
        self.recentComparisons = recentComparisons
        self.softWrap = softWrap
        self.diffLayout = diffLayout
    }
    private enum CodingKeys: String, CodingKey { case filters, repositoryMappings, recentComparisons, softWrap, diffLayout }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filters = try values.decode(ReviewFilters.self, forKey: .filters)
        repositoryMappings = try values.decode([String: String].self, forKey: .repositoryMappings)
        recentComparisons = try values.decode([ComparisonRequest].self, forKey: .recentComparisons)
        softWrap = try values.decodeIfPresent(Bool.self, forKey: .softWrap) ?? false
        diffLayout = try values.decodeIfPresent(DiffLayout.self, forKey: .diffLayout) ?? .split
    }
}

public final class ReviewStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Slopdiff", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func loadProgress(identity: String) throws -> ReviewProgress {
        try read("review-\(Self.digest(identity)).json", default: ReviewProgress())
    }
    public func saveProgress(_ progress: ReviewProgress, identity: String) throws {
        try write(progress, name: "review-\(Self.digest(identity)).json")
    }
    public func loadPreferences() throws -> ReviewPreferences {
        try read("preferences.json", default: ReviewPreferences())
    }
    public func savePreferences(_ preferences: ReviewPreferences) throws {
        try write(preferences, name: "preferences.json")
    }

    private func read<T: Decodable>(_ name: String, default value: T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let url = directory.appendingPathComponent(name)
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return value }
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        lock.lock(); defer { lock.unlock() }
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ReviewExport {
    public static func markdown(snapshot: ReviewSnapshot, progress: ReviewProgress) -> String {
        var header = "# Review: \(snapshot.title)\n\nRepository: \(snapshot.request.repository)\n" +
            "Comparison: \(snapshot.baseRevision) → \(snapshot.targetRevision ?? "Working tree")"
        if let url = snapshot.request.pullRequestURL { header += "\nPull request: \(url)" }
        var sections = [header]
        let fingerprints = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0.fingerprint) })
        for comment in progress.comments {
            let range = comment.startLine == comment.endLine ? "\(comment.startLine)" : "\(comment.startLine)-\(comment.endLine)"
            let stale = fingerprints[comment.path] == comment.fingerprint ? "" : " (stale location)"
            sections.append("## \(comment.path) · \(comment.side.rawValue) · \(range)\(stale)\n\n\(comment.text)")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}
