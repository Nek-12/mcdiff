import McDiffCore
import Foundation

func testGitHubClient() -> GitHubClient {
    GitHubClient(clientID: "test", credentials: TestGitHubCredentials())
}

private final class TestGitHubCredentials: GitHubCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func load() throws -> Data? { lock.withLock { data } }
    func save(_ data: Data?) throws { lock.withLock { self.data = data } }
}
