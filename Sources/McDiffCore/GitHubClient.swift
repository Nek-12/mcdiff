import Foundation

public enum GitHubError: Error, LocalizedError, Sendable, Equatable {
    case unauthenticated
    case configuration
    case expiredAuthorization
    case accessDenied
    case incompleteResults
    case invalidResponse
    case invalidPage
    case invalidSearch
    case credentials(String)
    case network(Int)
    case http(status: Int, advice: String)
    case oauth(String)

    public var errorDescription: String? {
        switch self {
        case .unauthenticated: return "Sign in to GitHub to continue. Your saved sign-in may have expired or been revoked."
        case .configuration: return "GitHub sign-in is not configured in this build of McDiff."
        case .expiredAuthorization: return "Your GitHub sign-in code expired. Start sign-in again for a new code."
        case .accessDenied: return "GitHub sign-in was declined. You can start sign-in again."
        case .incompleteResults: return "GitHub returned an incomplete pull request list. Try refreshing again."
        case .invalidResponse: return "GitHub returned an unexpected response. Try again; if it continues, update McDiff."
        case .invalidPage: return "Request a pull request page between 1 and 34. GitHub search exposes at most 1,000 results; narrow your search to find more."
        case .invalidSearch: return "Search using plain words, without GitHub qualifiers, quotes, or backslashes. Results always show your open pull requests."
        case .credentials(let message), .oauth(let message): return message
        case .network(let code): return "Could not connect to GitHub (network error \(code)). Check your connection and try again."
        case .http(let status, let advice): return "GitHub request failed (HTTP \(status)). \(advice)"
        }
    }
}

public struct GitHubUser: Decodable, Sendable, Equatable {
    public let login: String
    public let avatarURL: URL?
    private enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatarUrl"
    }
}

public struct GitHubDeviceAuthorization: Sendable {
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    fileprivate let deviceCode: String
    fileprivate let interval: TimeInterval
    fileprivate let id: UUID
}

/// Owns authentication and token rotation. No tokens or raw response bodies enter diagnostics.
public actor GitHubClient {
    private let clientID: String
    private let session: URLSession
    private let credentials: any GitHubCredentialStore
    private var generation = UUID()
    private var authorizationID: UUID?
    private var completingAuthorization = false
    private var refresh: (id: UUID, task: Task<GitHubCredential, Error>)?
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(clientID: String, session: URLSession? = nil,
                credentials: any GitHubCredentialStore = KeychainGitHubCredentialStore()) {
        self.init(clientID: clientID, session: session, credentials: credentials, clock: { Date() },
                  sleep: { try await Task.sleep(for: .seconds($0)) })
    }

    init(clientID: String, session: URLSession?, credentials: any GitHubCredentialStore,
         clock: @escaping @Sendable () -> Date,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.clientID = clientID
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
        self.credentials = credentials
        self.clock = clock
        self.sleep = sleep
    }

    public func currentUser() async throws -> GitHubUser? {
        guard try loadCredential() != nil else { return nil }
        return try await user(token: accessToken())
    }

    public func beginSignIn() async throws -> GitHubDeviceAuthorization {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitHubError.configuration }
        let id = UUID()
        authorizationID = id
        completingAuthorization = false
        let response: DeviceResponse = try await oauth(path: "/login/device/code", fields: ["client_id": clientID, "scope": "repo"])
        try Task.checkCancellation()
        guard authorizationID == id else { throw CancellationError() }
        if let error = response.error { throw Self.oauthError(error) }
        guard let expiresIn = response.expiresIn, expiresIn > 0, expiresIn <= 3600,
              let interval = response.interval, interval > 0, interval <= 3600,
              let deviceCode = response.deviceCode, !deviceCode.isEmpty,
              let userCode = response.userCode, !userCode.isEmpty,
              response.verificationUri == "https://github.com/login/device" else { throw GitHubError.invalidResponse }
        return GitHubDeviceAuthorization(userCode: userCode,
                                         verificationURL: URL(string: "https://github.com/login/device")!,
                                         expiresAt: clock().addingTimeInterval(expiresIn),
                                         deviceCode: deviceCode, interval: interval, id: id)
    }

    public func completeSignIn(_ authorization: GitHubDeviceAuthorization) async throws -> GitHubUser {
        guard authorizationID == authorization.id, !completingAuthorization else { throw CancellationError() }
        completingAuthorization = true
        defer {
            if authorizationID == authorization.id {
                authorizationID = nil
                completingAuthorization = false
            }
        }
        var interval = authorization.interval
        while clock() < authorization.expiresAt {
            try await sleep(min(interval, authorization.expiresAt.timeIntervalSince(clock())))
            try Task.checkCancellation()
            guard authorizationID == authorization.id else { throw CancellationError() }
            guard clock() < authorization.expiresAt else { break }
            let response: TokenResponse = try await oauth(path: "/login/oauth/access_token", fields: [
                "client_id": clientID, "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            switch response.error {
            case "authorization_pending": continue
            case "slow_down":
                guard response.interval.map({ $0 > 0 && $0 <= 3600 }) ?? true else { throw GitHubError.invalidResponse }
                interval = max(interval + 5, response.interval ?? 0)
                continue
            case .some(let error): throw Self.oauthError(error)
            case nil: break
            }
            let credential = try response.credential(now: clock())
            let user = try await user(token: credential.accessToken)
            try Task.checkCancellation()
            guard authorizationID == authorization.id else { throw CancellationError() }
            try credentials.save(JSONEncoder().encode(credential))
            generation = UUID()
            refresh?.task.cancel()
            refresh = nil
            return user
        }
        throw GitHubError.expiredAuthorization
    }

    public func signOut() throws {
        // Do not report success if Keychain could not remove the durable credential.
        try credentials.save(nil)
        generation = UUID()
        authorizationID = nil
        completingAuthorization = false
        refresh?.task.cancel()
        refresh = nil
    }

    public func pullRequests(query: String = "", page: Int = 1) async throws -> PRPage {
        let pageSize = PRPage.pageSize
        let searchMaximum = 1000
        guard (1...((searchMaximum + pageSize - 1) / pageSize)).contains(page) else { throw GitHubError.invalidPage }
        guard !query.contains(where: { ":\"\\".contains($0) }) else { throw GitHubError.invalidSearch }
        // Quote every word so Boolean operators and grouping cannot broaden the authored-open scope.
        let terms = query.split(whereSeparator: \.isWhitespace).map { "\"\($0)\"" }.joined(separator: " ")
        let token = try await accessToken()
        let generation = generation
        let user = try await user(token: token)
        let scope = "is:pr is:open author:\(user.login)"
        let response: SearchResponse = try await api(path: "/search/issues", token: token, query: [
            URLQueryItem(name: "q", value: terms.isEmpty ? scope : "\(scope) \(terms)"),
            URLQueryItem(name: "sort", value: "created"), URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: String(pageSize)), URLQueryItem(name: "page", value: String(page))
        ])
        guard self.generation == generation else { throw CancellationError() }
        guard !response.incompleteResults else { throw GitHubError.incompleteResults }
        guard response.totalCount >= 0, response.items.count <= pageSize else { throw GitHubError.invalidResponse }
        let offset = (page - 1) * pageSize
        let results = try response.items.prefix(searchMaximum - offset).map { item in
            guard let pr = try? GitHubPR.parse(item.htmlUrl), pr.url == item.htmlUrl else { throw GitHubError.invalidResponse }
            return PRSummary(pr: pr, title: item.title, createdAt: item.createdAt, isDraft: item.draft)
        }
        return PRPage(items: results, totalCount: min(response.totalCount, searchMaximum))
    }

    public func revisions(for pr: GitHubPR) async throws -> GitHubPRRevisions {
        let token = try await accessToken()
        let generation = generation
        let response: RevisionResponse = try await api(path: "/repos/\(pr.repositoryKey)/pulls/\(pr.number)", token: token)
        guard self.generation == generation else { throw CancellationError() }
        return try GitHubPRRevisions(base: response.base.sha, head: response.head.sha, title: response.title)
    }

    private func loadCredential() throws -> GitHubCredential? {
        guard let data = try credentials.load() else { return nil }
        guard let value = try? JSONDecoder().decode(GitHubCredential.self, from: data),
              !value.accessToken.isEmpty else {
            throw GitHubError.credentials("The saved GitHub sign-in is unreadable. Sign out and sign in again.")
        }
        return value
    }

    private func accessToken() async throws -> String {
        try Task.checkCancellation()
        guard let credential = try loadCredential() else { throw GitHubError.unauthenticated }
        guard let expiry = credential.expiresAt, expiry <= clock().addingTimeInterval(30) else { return credential.accessToken }
        guard let refreshToken = credential.refreshToken,
              credential.refreshExpiresAt.map({ $0 > clock() }) ?? true else { throw GitHubError.unauthenticated }
        let generation = generation
        let pending: (id: UUID, task: Task<GitHubCredential, Error>)
        if let refresh { pending = refresh }
        else {
            pending = (UUID(), Task {
                let response: TokenResponse = try await self.oauth(path: "/login/oauth/access_token", fields: [
                    "client_id": self.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken
                ])
                if let error = response.error { throw Self.oauthError(error) }
                let rotated = try response.credential(now: self.clock())
                guard self.generation == generation else { throw CancellationError() }
                try self.credentials.save(JSONEncoder().encode(rotated))
                return rotated
            })
            refresh = pending
        }
        do {
            let rotated = try await pending.task.value
            guard self.generation == generation else { throw CancellationError() }
            if refresh?.id == pending.id { refresh = nil }
            try Task.checkCancellation()
            return rotated.accessToken
        } catch {
            if refresh?.id == pending.id { refresh = nil }
            throw error
        }
    }

    private func user(token: String) async throws -> GitHubUser {
        let generation = generation
        let user: GitHubUser = try await api(path: "/user", token: token)
        guard self.generation == generation else { throw CancellationError() }
        guard !user.login.isEmpty, user.login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw GitHubError.invalidResponse
        }
        return user
    }

    private func api<T: Decodable>(path: String, token: String, query: [URLQueryItem] = []) async throws -> T {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.github.com"
        url.path = path
        url.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return try await send(request)
    }

    private func oauth<T: Decodable>(path: String, fields: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://github.com\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        return try await send(request)
    }

    private func send<T: Decodable>(_ original: URLRequest) async throws -> T {
        try Task.checkCancellation()
        var request = original
        request.setValue("McDiff", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: RejectGitHubRedirects()) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw GitHubError.network((error as NSError).code)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        if http.value(forHTTPHeaderField: "X-GitHub-SSO") != nil {
            throw GitHubError.http(status: http.statusCode,
                                  advice: "Authorize McDiff for your organization's SSO in GitHub, then try again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw GitHubError.unauthenticated }
            let advice: String
            if http.statusCode == 429 || http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
                        http.value(forHTTPHeaderField: "Retry-After") != nil {
                advice = "GitHub's rate limit was reached. Wait a few minutes before trying again."
            } else if http.statusCode == 403 || http.statusCode == 404 {
                advice = "Check that your GitHub account and McDiff have access to this repository, including any organization OAuth restrictions."
            } else if (300..<400).contains(http.statusCode) {
                advice = "GitHub redirected the request. Open the current repository URL and try again."
            } else { advice = "Try again shortly." }
            throw GitHubError.http(status: http.statusCode, advice: advice)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(T.self, from: data) else { throw GitHubError.invalidResponse }
        return decoded
    }

    private static func oauthError(_ error: String) -> GitHubError {
        switch error {
        case "expired_token": return .expiredAuthorization
        case "access_denied": return .accessDenied
        case "bad_refresh_token", "invalid_grant": return .unauthenticated
        case "incorrect_client_credentials": return .configuration
        case "device_flow_disabled": return .oauth("Enable device flow in McDiff's GitHub OAuth app registration, then try again.")
        default: return .oauth("GitHub could not authorize McDiff. Start sign-in again; if it continues, check the OAuth app configuration.")
        }
    }
}

final class RejectGitHubRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct DeviceResponse: Decodable {
    let deviceCode: String?
    let userCode: String?
    let verificationUri: String?
    let expiresIn: TimeInterval?
    let interval: TimeInterval?
    let error: String?
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let expiresIn: TimeInterval?
    let refreshToken: String?
    let refreshTokenExpiresIn: TimeInterval?
    let interval: TimeInterval?
    let error: String?

    func credential(now: Date) throws -> GitHubCredential {
        guard let accessToken, !accessToken.isEmpty, tokenType?.lowercased() == "bearer",
              expiresIn.map({ $0 > 0 }) ?? true,
              refreshTokenExpiresIn.map({ $0 > 0 }) ?? true else { throw GitHubError.invalidResponse }
        return GitHubCredential(accessToken: accessToken, expiresAt: expiresIn.map { now.addingTimeInterval($0) },
                                refreshToken: refreshToken, refreshExpiresAt: refreshTokenExpiresIn.map { now.addingTimeInterval($0) })
    }
}

private struct SearchResponse: Decodable {
    let totalCount: Int
    let incompleteResults: Bool
    let items: [Item]
    struct Item: Decodable {
        let htmlUrl: String
        let title: String
        let createdAt: Date
        let draft: Bool
    }
}

private struct RevisionResponse: Decodable {
    let title: String
    let base: Revision
    let head: Revision
    struct Revision: Decodable { let sha: String }
}
