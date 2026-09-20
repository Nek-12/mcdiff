import Foundation
import XCTest
@testable import McDiffCore

final class GitHubClientTests: XCTestCase {
    func testFailedReplacementSignInPreservesCredentials() async throws {
        let (client, transport, store) = makeClient(signedIn: true)
        let previous = try store.load()
        transport.responses = [.json(device), .json(#"{"error":"access_denied"}"#)]
        let authorization = try await client.beginSignIn()
        do {
            _ = try await client.completeSignIn(authorization)
            XCTFail("Expected denied authorization")
        } catch {}
        XCTAssertEqual(try store.load(), previous)
    }

    override func tearDown() {
        GitHubStubProtocol.clear()
        super.tearDown()
    }

    func testSignedOutDoesNotMakeRequestsAndRejectsInbox() async throws {
        let (client, transport, _) = makeClient()
        let user = try await client.currentUser()
        XCTAssertNil(user)
        await assertError(.unauthenticated) { _ = try await client.pullRequests() }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCurrentUserDecodesAvatarURLFromGitHubResponse() async throws {
        let (client, transport, _) = makeClient(signedIn: true)
        transport.responses = [.json(#"{"login":"nek-12","avatar_url":"https://avatars.githubusercontent.com/u/123?v=4"}"#)]
        let user = try await client.currentUser()
        XCTAssertEqual(user?.avatarURL?.absoluteString, "https://avatars.githubusercontent.com/u/123?v=4")
    }

    func testSignInPollsAtServerIntervalSlowsDownAndPersistsOnlyAfterIdentityLookup() async throws {
        let (client, transport, store) = makeClient()
        transport.responses = [.json(device), .json(#"{"error":"authorization_pending"}"#),
                               .json(#"{"error":"slow_down"}"#), .json(token),
                               .json(#"{"login":"nek-12","avatar_url":"https://avatars.githubusercontent.com/u/123"}"#)]
        let authorization = try await client.beginSignIn()
        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.verificationURL.absoluteString, "https://github.com/login/device")
        XCTAssertNil(try store.load())
        let user = try await client.completeSignIn(authorization)
        XCTAssertEqual(user.login, "nek-12")
        XCTAssertEqual(user.avatarURL?.absoluteString, "https://avatars.githubusercontent.com/u/123")
        XCTAssertEqual(transport.clock.waits, [5, 5, 10])
        XCTAssertEqual(try store.credential()?.accessToken, "test-access")
        let requests = transport.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(body(requests[0]), "client_id=public-test-client&scope=repo")
        XCTAssertTrue(body(requests[1]).contains("device_code=private-device-code"))
        XCTAssertFalse(body(requests[1]).contains("client_secret"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "User-Agent"), "McDiff")
        try await client.signOut()
        XCTAssertNil(try store.load())
    }

    func testDeniedAndExpiredCodesDoNotSaveCredentials() async throws {
        for (response, expected) in [
            (#"{"error":"access_denied"}"#, GitHubError.accessDenied),
            (#"{"error":"expired_token"}"#, GitHubError.expiredAuthorization)
        ] {
            let (client, transport, store) = makeClient()
            transport.responses = [.json(device), .json(response)]
            let authorization = try await client.beginSignIn()
            await assertError(expected) { _ = try await client.completeSignIn(authorization) }
            XCTAssertNil(try store.load())
        }
    }

    func testPollingHonorsLongerServerSlowDownInterval() async throws {
        let (client, transport, _) = makeClient()
        transport.responses = [.json(device), .json(#"{"error":"slow_down","interval":20}"#),
                               .json(token), .json(#"{"login":"nek-12"}"#)]
        let authorization = try await client.beginSignIn()
        _ = try await client.completeSignIn(authorization)
        XCTAssertEqual(transport.clock.waits, [5, 20])
    }

    func testLocalExpiryStopsPolling() async throws {
        let (client, transport, store) = makeClient()
        transport.responses = [.json(device.replacingOccurrences(of: "900", with: "5"))]
        let authorization = try await client.beginSignIn()
        await assertError(.expiredAuthorization) { _ = try await client.completeSignIn(authorization) }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNil(try store.load())
    }

    func testCancelledSignInNeverSavesToken() async throws {
        let store = MemoryGitHubCredentials()
        let transport = GitHubTransport()
        transport.responses = [.json(device)]
        let client = GitHubClient(clientID: "client", session: transport.session(), credentials: store,
                                  clock: { transport.clock.now }, sleep: { _ in throw CancellationError() })
        let authorization = try await client.beginSignIn()
        do { _ = try await client.completeSignIn(authorization); XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertNil(try store.load())
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testSignOutInvalidatesOutstandingDeviceCode() async throws {
        let (client, transport, store) = makeClient()
        transport.responses = [.json(device)]
        let authorization = try await client.beginSignIn()
        try await client.signOut()
        do { _ = try await client.completeSignIn(authorization); XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertNil(try store.load())
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testInvalidIdentityDoesNotPersistTokenAndDiagnosticsNeverIncludeResponse() async throws {
        let (client, transport, store) = makeClient()
        transport.responses = [.json(device), .json(token), .json(#"{"login":"nek is:closed secret"}"#)]
        let authorization = try await client.beginSignIn()
        await assertError(.invalidResponse) { _ = try await client.completeSignIn(authorization) }
        XCTAssertNil(try store.load())
    }

    func testDeviceConfigurationAndVerificationURLValidation() async throws {
        for (response, expected) in [
            (device.replacingOccurrences(of: "https://github.com/login/device", with: "https://evil.invalid/login/device"), GitHubError.invalidResponse),
            (#"{"error":"incorrect_client_credentials","error_description":"test-access"}"#, .configuration)
        ] {
            let (client, transport, _) = makeClient()
            transport.responses = [.json(response)]
            await assertError(expected) { _ = try await client.beginSignIn() }
        }
        let (client, transport, _) = makeClient(clientID: "")
        await assertError(.configuration) { _ = try await client.beginSignIn() }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testInboxUsesAuthenticatedAuthorAndBoundedPagination() async throws {
        let (client, transport, _) = makeClient(signedIn: true)
        transport.responses = [.json(#"{"login":"nek-12"}"#),
                               .json(search(items: (1...30).map(item).joined(separator: ","), total: 35)),
                               .json(#"{"login":"nek-12"}"#),
                               .json(search(items: (31...35).map(item).joined(separator: ","), total: 35))]
        let first = try await client.pullRequests()
        XCTAssertEqual(first.items.count, 30)
        XCTAssertEqual(first.totalCount, 35)
        XCTAssertTrue(first.items[0].isDraft)
        XCTAssertEqual(first.items[0].title, "Review 1")
        XCTAssertEqual(transport.requests.count, 2)
        let second = try await client.pullRequests(page: 2)
        XCTAssertEqual(second.items.map(\.pr.number), Array(31...35))
        XCTAssertEqual(second.totalCount, 35)
        let query = URLComponents(url: transport.requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "q" }?.value, "is:pr is:open author:nek-12")
        XCTAssertEqual(query?.first { $0.name == "sort" }?.value, "created")
        XCTAssertEqual(query?.first { $0.name == "order" }?.value, "desc")
        XCTAssertEqual(query?.first { $0.name == "per_page" }?.value, "30")
        XCTAssertEqual(URLComponents(url: transport.requests[3].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value, "2")
    }

    func testInboxSearchIsServerSideAndRetainsScopeOnEveryPage() async throws {
        let (client, transport, _) = makeClient(signedIn: true)
        for page in 1...2 {
            transport.responses = [.json(#"{"login":"nek-12"}"#),
                                   .json(search(items: item(page), total: 60))]
            let result = try await client.pullRequests(query: "  fix OR (failure)  ", page: page)
            XCTAssertEqual(result.items.first?.pr.number, page)
            let query = URLComponents(url: transport.requests.last!.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "q" }?.value,
                           #"is:pr is:open author:nek-12 "fix" "OR" "(failure)""#)
            XCTAssertEqual(query?.first { $0.name == "page" }?.value, String(page))
        }
    }

    func testInboxRejectsPartialSearchUnsafeURLsInvalidDatesAndInvalidPages() async throws {
        for (response, expected) in [
            (search(items: item(1), incomplete: true), GitHubError.incompleteResults),
            (search(items: item(1).replacingOccurrences(of: "github.com", with: "evil.invalid")), .invalidResponse),
            (search(items: item(1).replacingOccurrences(of: "2026-09-20T10:00:00Z", with: "yesterday")), .invalidResponse),
            (search(items: "", total: -1), .invalidResponse),
            (search(items: (1...31).map(item).joined(separator: ","), total: 31), .invalidResponse)
        ] {
            let (client, transport, _) = makeClient(signedIn: true)
            transport.responses = [.json(#"{"login":"nek-12"}"#), .json(response)]
            await assertError(expected) { _ = try await client.pullRequests() }
        }
        let (client, transport, _) = makeClient(signedIn: true)
        for page in [0, -1, 35, Int.max] {
            await assertError(.invalidPage) { _ = try await client.pullRequests(page: page) }
        }
        for query in ["author:someone", "is:closed", #"fix" OR is:issue"#, #"fix\failure"#] {
            await assertError(.invalidSearch) { _ = try await client.pullRequests(query: query) }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testInboxStopsAtSearchMaximumEvenWhenMoreResultsExist() async throws {
        let (client, transport, _) = makeClient(signedIn: true)
        for (page, range) in [(33, 961...990), (34, 991...1000)] {
            transport.responses = [.json(#"{"login":"nek-12"}"#),
                                   .json(search(items: range.map(item).joined(separator: ","), total: 5000))]
            let result = try await client.pullRequests(page: page)
            XCTAssertEqual(result.items.map(\.pr.number), Array(range))
            XCTAssertEqual(result.totalCount, 1000)
        }
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testInboxEmptyAndExactFullPageReportTheirExtent() async throws {
        for count in [0, 30] {
            let (client, transport, _) = makeClient(signedIn: true)
            transport.responses = [.json(#"{"login":"nek-12"}"#),
                                   .json(search(items: (0..<count).map { item($0 + 1) }.joined(separator: ","), total: count))]
            let result = try await client.pullRequests(query: " \n ")
            XCTAssertEqual(result.items.count, count)
            XCTAssertEqual(result.totalCount, count)
        }
    }

    func testTransportFailureIsActionableWithoutEchoingRequestSecrets() async throws {
        let (client, _, _) = makeClient(signedIn: true)
        await assertError(.network(URLError.resourceUnavailable.rawValue)) { _ = try await client.currentUser() }
    }

    func testInvalidCredentialRequiresExplicitSignOutWithoutNetwork() async throws {
        let (client, transport, store) = makeClient()
        try store.save(Data("not a credential".utf8))
        do { _ = try await client.currentUser(); XCTFail("Expected invalid saved credential") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Sign out and sign in again")) }
        XCTAssertTrue(transport.requests.isEmpty)
        try await client.signOut()
        XCTAssertNil(try store.load())
    }

    func testPRMetadataValidatesObjectIDs() async throws {
        let (client, transport, _) = makeClient(signedIn: true)
        let base = String(repeating: "a", count: 40), head = String(repeating: "b", count: 64)
        transport.responses = [.json(#"{"base":{"sha":"\#(base)"},"head":{"sha":"\#(head)"}}"#),
                               .json(#"{"base":{"sha":"--evil"},"head":{"sha":"\#(head)"}}"#)]
        let pr = try GitHubPR.parse("https://github.com/owner/repo/pull/42")
        let revisions = try await client.revisions(for: pr)
        XCTAssertEqual(revisions.base, base)
        XCTAssertEqual(revisions.head, head)
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/repos/owner/repo/pulls/42")
        do { _ = try await client.revisions(for: pr); XCTFail("Expected invalid SHA") }
        catch { XCTAssertTrue(error.localizedDescription.contains("invalid commit")) }
    }

    func testHTTPFailuresSurfaceActionableSafeMessagesIncludingPartialSSO() async throws {
        for (status, headers, phrase) in [
            (401, [:], "Sign in"),
            (403, ["X-GitHub-SSO": "required; url=https://github.com/secret"], "SSO"),
            (200, ["X-GitHub-SSO": "partial-results; organizations=123"], "SSO"),
            (429, [:], "rate limit"),
            (403, ["X-RateLimit-Remaining": "0"], "rate limit"),
            (404, [:], "access"),
            (500, [:], "Try again"),
            (302, ["Location": "https://evil.invalid"], "redirected")
        ] {
            let (client, transport, _) = makeClient(signedIn: true)
            transport.responses = [.init(status: status, headers: headers, data: Data("test-access secret body".utf8))]
            do { _ = try await client.currentUser(); XCTFail("Expected failure") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains(phrase), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("test-access"))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
                if status == 401 { XCTAssertEqual(error as? GitHubError, .unauthenticated) }
            }
        }
    }

    func testExpiredTokenRefreshesAndPersistsRotationWithoutClientSecret() async throws {
        let (client, transport, store) = makeClient()
        try store.save(JSONEncoder().encode(GitHubCredential(accessToken: "old", expiresAt: .distantPast,
                                                            refreshToken: "test-refresh", refreshExpiresAt: .distantFuture)))
        transport.responses = [.json(tokenWithRefresh), .json(#"{"login":"nek-12"}"#)]
        let user = try await client.currentUser()
        XCTAssertEqual(user?.login, "nek-12")
        XCTAssertEqual(try store.credential()?.refreshToken, "rotated-refresh")
        XCTAssertEqual(body(transport.requests[0]), "client_id=public-test-client&grant_type=refresh_token&refresh_token=test-refresh")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer rotated-access")
    }

    func testExpiredRefreshTokenRequiresSignInWithoutNetwork() async throws {
        let (client, transport, store) = makeClient()
        try store.save(JSONEncoder().encode(GitHubCredential(accessToken: "old", expiresAt: .distantPast,
                                                            refreshToken: "expired", refreshExpiresAt: .distantPast)))
        await assertError(.unauthenticated) { _ = try await client.currentUser() }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRevokedRefreshTokenRequiresSignInWithoutExposingServerBody() async throws {
        let (client, transport, store) = makeClient()
        try store.save(JSONEncoder().encode(GitHubCredential(accessToken: "old", expiresAt: .distantPast,
                                                            refreshToken: "test-refresh", refreshExpiresAt: .distantFuture)))
        transport.responses = [.json(#"{"error":"bad_refresh_token","error_description":"test-refresh"}"#)]
        await assertError(.unauthenticated) { _ = try await client.currentUser() }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.credential()?.accessToken, "old")
    }

    func testConcurrentRequestsShareOneTokenRotation() async throws {
        let (client, transport, store) = makeClient()
        try store.save(JSONEncoder().encode(GitHubCredential(accessToken: "old", expiresAt: .distantPast,
                                                            refreshToken: "test-refresh", refreshExpiresAt: .distantFuture)))
        let gate = GitHubResponseGate()
        transport.responses = [.json(tokenWithRefresh, gate: gate)] + Array(repeating: .json(#"{"login":"nek-12"}"#), count: 20)
        let tasks = (0..<20).map { _ in Task { try await client.currentUser() } }
        await fulfillment(of: [gate.started], timeout: 3)
        gate.release()
        for task in tasks {
            let user = try await task.value
            XCTAssertEqual(user?.login, "nek-12")
        }
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/login/oauth/access_token" }.count, 1)
        XCTAssertEqual(try store.credential()?.refreshToken, "rotated-refresh")
    }

    func testSignOutDuringRefreshCannotRestoreCredentialOrReturnOldAccount() async throws {
        let (client, transport, store) = makeClient()
        try store.save(JSONEncoder().encode(GitHubCredential(accessToken: "old", expiresAt: .distantPast,
                                                            refreshToken: "test-refresh", refreshExpiresAt: .distantFuture)))
        let gate = GitHubResponseGate()
        transport.responses = [.json(tokenWithRefresh, gate: gate)]
        let task = Task { try await client.currentUser() }
        await fulfillment(of: [gate.started], timeout: 3)
        try await client.signOut()
        gate.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertNil(try store.load())
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testSignOutDuringIdentityValidationCannotSaveSignIn() async throws {
        let (client, transport, store) = makeClient()
        let gate = GitHubResponseGate()
        transport.responses = [.json(device), .json(token), .json(#"{"login":"nek-12"}"#, gate: gate)]
        let authorization = try await client.beginSignIn()
        let task = Task { try await client.completeSignIn(authorization) }
        await fulfillment(of: [gate.started], timeout: 3)
        try await client.signOut()
        gate.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertNil(try store.load())
    }

    func testCredentialWriteFailureDoesNotReportSuccessfulSignInOrSignOut() async throws {
        let (client, transport, store) = makeClient()
        transport.responses = [.json(device), .json(token), .json(#"{"login":"nek-12"}"#)]
        store.writeError = .credentials("Keychain locked")
        let authorization = try await client.beginSignIn()
        await assertError(.credentials("Keychain locked")) { _ = try await client.completeSignIn(authorization) }
        await assertError(.credentials("Keychain locked")) { try await client.signOut() }
    }

    func testRejectsCrossHostRedirectBeforeForwardingAuthorization() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://api.github.com/user")!
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var redirected = URLRequest(url: URL(string: "https://evil.invalid/steal")!)
        redirected.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        var called = false
        RejectGitHubRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
            called = true
            XCTAssertNil($0)
        }
        XCTAssertTrue(called)
    }

    private let device = #"{"device_code":"private-device-code","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
    private let token = #"{"access_token":"test-access","token_type":"bearer","scope":"repo"}"#
    private let tokenWithRefresh = #"{"access_token":"rotated-access","token_type":"bearer","expires_in":28800,"refresh_token":"rotated-refresh","refresh_token_expires_in":15897600}"#

    private func makeClient(signedIn: Bool = false, clientID: String = "public-test-client") -> (GitHubClient, GitHubTransport, MemoryGitHubCredentials) {
        let transport = GitHubTransport()
        let store = MemoryGitHubCredentials()
        if signedIn {
            try! store.save(JSONEncoder().encode(GitHubCredential(accessToken: "test-access", expiresAt: nil, refreshToken: nil, refreshExpiresAt: nil)))
        }
        let client = GitHubClient(clientID: clientID, session: transport.session(), credentials: store,
                                  clock: { transport.clock.now }, sleep: { transport.clock.advance($0) })
        return (client, transport, store)
    }

    private func assertError(_ expected: GitHubError, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? GitHubError, expected, file: file, line: line) }
    }

    private func item(_ number: Int) -> String {
        #"{"html_url":"https://github.com/owner/repo/pull/\#(number)","title":"Review \#(number)","created_at":"2026-09-20T10:00:00Z","draft":true}"#
    }

    private func search(items: String, total: Int = 1, incomplete: Bool = false) -> String {
        #"{"total_count":\#(total),"incomplete_results":\#(incomplete),"items":[\#(items)]}"#
    }

    private func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = stream.read(&bytes, maxLength: bytes.count)
        return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
    }
}

private final class MemoryGitHubCredentials: GitHubCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var writeError: GitHubError?
    func load() throws -> Data? { lock.withLock { data } }
    func save(_ data: Data?) throws {
        try lock.withLock {
            if let writeError { throw writeError }
            self.data = data
        }
    }
    func credential() throws -> GitHubCredential? {
        try load().map { try JSONDecoder().decode(GitHubCredential.self, from: $0) }
    }
}

private final class TestGitHubClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_789_900_000)
    private var intervals: [TimeInterval] = []
    var now: Date { lock.withLock { date } }
    var waits: [TimeInterval] { lock.withLock { intervals } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock { intervals.append(seconds); date.addTimeInterval(seconds) }
    }
}

private final class GitHubTransport: @unchecked Sendable {
    struct Response {
        let status: Int
        let headers: [String: String]
        let data: Data
        var gate: GitHubResponseGate?
        static func json(_ text: String, gate: GitHubResponseGate? = nil) -> Self {
            .init(status: 200, headers: [:], data: Data(text.utf8), gate: gate)
        }
    }
    private let lock = NSLock()
    private var queue: [Response] = []
    private var recorded: [URLRequest] = []
    let clock = TestGitHubClock()
    var requests: [URLRequest] { lock.withLock { recorded } }
    var responses: [Response] {
        get { lock.withLock { queue } }
        set { lock.withLock { queue = newValue } }
    }
    func reply(to request: URLRequest) -> Response? {
        lock.withLock {
            recorded.append(request)
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }
    func session() -> URLSession {
        let id = UUID().uuidString
        GitHubStubProtocol.register(self, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-ID": id]
        return URLSession(configuration: configuration)
    }
}

private final class GitHubStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var transports: [String: GitHubTransport] = [:]
    static func register(_ transport: GitHubTransport, id: String) { lock.withLock { transports[id] = transport } }
    static func clear() { lock.withLock { transports.removeAll() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let transport = Self.lock.withLock { Self.transports[request.value(forHTTPHeaderField: "X-Test-ID") ?? ""] }
        guard let response = transport?.reply(to: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let deliver = {
            let http = HTTPURLResponse(url: self.request.url!, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: response.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if let gate = response.gate { gate.hold(deliver) } else { deliver() }
    }
    override func stopLoading() {}
}

private final class GitHubResponseGate {
    let started = XCTestExpectation(description: "Request is awaiting its response")
    private let lock = NSLock()
    private var delivery: (() -> Void)?
    func hold(_ delivery: @escaping () -> Void) {
        lock.withLock { self.delivery = delivery }
        started.fulfill()
    }
    func release() {
        let delivery = lock.withLock {
            let result = self.delivery
            self.delivery = nil
            return result
        }
        delivery?()
    }
}
