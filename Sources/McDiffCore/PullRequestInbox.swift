import Foundation

public struct PRPage: Sendable, Equatable {
    public static let pageSize = 30
    public let items: [PRSummary]
    public let totalCount: Int

    public init(items: [PRSummary], totalCount: Int) {
        self.items = items
        self.totalCount = totalCount
    }
}

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
