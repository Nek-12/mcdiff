import Foundation
import CryptoKit
import Darwin

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

public struct CompletedReviewMetadata: Codable, Sendable {
    public let id: UUID
    public let completedAt: Date
    public let comparisonIdentity: String
    public let title: String
    public let request: ComparisonRequest
    public let baseRevision: String
    public let targetRevision: String?
    public let fileFingerprints: [String: String]

    init(snapshot: ReviewSnapshot) {
        id = UUID()
        completedAt = Date()
        comparisonIdentity = snapshot.identity
        title = snapshot.title
        request = snapshot.request
        baseRevision = snapshot.baseRevision
        targetRevision = snapshot.targetRevision
        fileFingerprints = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0.fingerprint) })
    }
}

public final class ReviewStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("McDiff", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func loadProgress(identity: String) throws -> ReviewProgress {
        try lock.withLock { try read(progressName(identity), default: ReviewProgress()) }
    }
    public func saveProgress(_ progress: ReviewProgress, identity: String) throws {
        try lock.withLock { try write(progress, name: progressName(identity)) }
    }
    public func loadPreferences() throws -> ReviewPreferences {
        try lock.withLock { try read("preferences.json", default: ReviewPreferences()) }
    }
    public func savePreferences(_ preferences: ReviewPreferences) throws {
        try lock.withLock { try write(preferences, name: "preferences.json") }
    }

    /// Archives saved progress and returns its round directory. A round is complete only
    /// when progress.json exists; metadata-only directories are uncommitted preparations.
    public func finishReview(snapshot: ReviewSnapshot) throws -> URL {
        try lock.withLock {
            let name = progressName(snapshot.identity)
            let activeURL = directory.appendingPathComponent(name)
            let savedData: Data
            do { savedData = try Data(contentsOf: activeURL) }
            catch CocoaError.fileReadNoSuchFile { savedData = try JSONEncoder().encode(ReviewProgress()) }
            // Never archive unreadable progress and silently replace it with an empty review.
            _ = try JSONDecoder().decode(ReviewProgress.self, from: savedData)

            let metadata = CompletedReviewMetadata(snapshot: snapshot)
            let archive = directory.appendingPathComponent("completed-reviews", isDirectory: true)
                .appendingPathComponent(metadata.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try JSONEncoder().encode(metadata).write(to: archive.appendingPathComponent("metadata.json"), options: .atomic)
            if !FileManager.default.fileExists(atPath: activeURL.path) {
                try savedData.write(to: activeURL, options: .atomic)
            }

            let completedURL = archive.appendingPathComponent("progress.json")
            // Both paths share the store volume. Rename is the single atomic commit:
            // it preserves the exact saved bytes and removes the active round together.
            guard rename(activeURL.path, completedURL.path) == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                    NSLocalizedDescriptionKey: "Could not finish the review: \(String(cString: strerror(code))). Saved review progress is unchanged.",
                    NSFilePathErrorKey: activeURL.path
                ])
            }
            return archive
        }
    }

    private func progressName(_ identity: String) -> String {
        "review-\(Self.digest(identity)).json"
    }

    private func read<T: Decodable>(_ name: String, default value: T) throws -> T {
        let url = directory.appendingPathComponent(name)
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return value }
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
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
