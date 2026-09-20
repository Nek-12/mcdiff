import Foundation

public struct PRSummary: Sendable, Equatable {
    public let pr: GitHubPR
    public let title: String
    public let createdAt: Date
    public let isDraft: Bool

    public init(pr: GitHubPR, title: String, createdAt: Date, isDraft: Bool) {
        self.pr = pr
        self.title = title
        self.createdAt = createdAt
        self.isDraft = isDraft
    }
}
