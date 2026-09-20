import AppKit
import XCTest
@testable import McDiff
@testable import McDiffCore

final class GitHubSignInTests: XCTestCase {
    private let device = #"{"device_code":"secret-device-code","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
    private let token = #"{"access_token":"secret-access-token","token_type":"bearer","scope":"repo"}"#

    @MainActor
    private func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views)
    }

    @MainActor
    private func button(_ title: String, _ sheet: GitHubSignInController) throws -> NSButton {
        try XCTUnwrap(views(try XCTUnwrap(sheet.window?.contentView)).compactMap { $0 as? NSButton }
            .first { $0.title == title })
    }

    @MainActor
    private func text(_ sheet: GitHubSignInController) -> String {
        views(sheet.window!.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
    }

    @MainActor
    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for sign-in")
    }

    @MainActor
    func testCodeRequiresExplicitCopyBrowserActionAndSuccessOccursOnce() async throws {
        _ = NSApplication.shared
        let transport = SignInTransport([device, token, #"{"login":"nek-12"}"#])
        let store = SignInCredentials()
        let client = transport.client(store: store)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Existing clipboard", forType: .string)
        var opened: [URL] = []
        var users: [GitHubUser] = []
        let sheet = GitHubSignInController(client: client, onSignedIn: { users.append($0) },
            pasteboard: pasteboard, openBrowser: { opened.append($0); return true })
        XCTAssertEqual(transport.requestCount, 0)
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { sheet.close(); parent.close(); transport.finish() }
        sheet.present(on: parent)
        XCTAssertTrue(text(sheet).contains("Requesting"))
        await waitFor { (try? self.button("Copy code & continue", sheet).isEnabled) == true }
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing clipboard")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertTrue(text(sheet).contains("ABCD-EFGH"))
        XCTAssertFalse(text(sheet).contains("secret-device-code"))
        XCTAssertTrue(text(sheet).contains("expires at"))
        let proceed = try button("Copy code & continue", sheet)
        proceed.performClick(nil)
        proceed.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "ABCD-EFGH")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/login/device"])
        await waitFor { users.count == 1 }
        XCTAssertEqual(users.first?.login, "nek-12")
        XCTAssertNotNil(try store.load())
        XCTAssertNil(parent.attachedSheet)
        XCTAssertFalse(text(sheet).contains("secret-access-token"))
    }

    @MainActor
    func testDeniedAndExpiredAuthorizationKeepSheetAndRetryWithFreshCode() async throws {
        _ = NSApplication.shared
        for error in ["access_denied", "expired_token"] {
            let transport = SignInTransport([device, "{\"error\":\"\(error)\"}",
                device.replacingOccurrences(of: "ABCD-EFGH", with: "IJKL-MNOP")])
            let store = SignInCredentials()
            let pasteboard = NSPasteboard.withUniqueName()
            let sheet = GitHubSignInController(client: transport.client(store: store),
                onSignedIn: { _ in XCTFail("Unexpected success") },
                pasteboard: pasteboard, openBrowser: { _ in true })
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            defer { sheet.close(); parent.close(); pasteboard.releaseGlobally(); transport.finish() }
            sheet.present(on: parent)
            await waitFor { (try? self.button("Copy code & continue", sheet).isEnabled) == true }
            try button("Copy code & continue", sheet).performClick(nil)
            await waitFor { (try? self.button("Retry", sheet).isHidden) == false }
            XCTAssertTrue(text(sheet).contains(error == "access_denied" ? "declined" : "expired"))
            XCTAssertNotNil(parent.attachedSheet)
            XCTAssertNil(try store.load())
            try button("Retry", sheet).performClick(nil)
            await waitFor { self.text(sheet).contains("IJKL-MNOP") }
            XCTAssertEqual(pasteboard.string(forType: .string), "ABCD-EFGH")
            XCTAssertTrue(try button("Copy code & continue", sheet).isEnabled)
        }
    }

    @MainActor
    func testCancelDuringCodeRequestAndPollingNeverCallsSuccessOrWritesCredentials() async throws {
        _ = NSApplication.shared
        for cancelDuringPolling in [false, true] {
            let transport = SignInTransport(cancelDuringPolling ? [device, nil] : [nil])
            let store = SignInCredentials()
            let pasteboard = NSPasteboard.withUniqueName()
            var success = false
            let sheet = GitHubSignInController(client: transport.client(store: store),
                onSignedIn: { _ in success = true }, pasteboard: pasteboard, openBrowser: { _ in true })
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            defer { sheet.close(); parent.close(); pasteboard.releaseGlobally(); transport.finish() }
            sheet.present(on: parent)
            if cancelDuringPolling {
                await waitFor { (try? self.button("Copy code & continue", sheet).isEnabled) == true }
                try button("Copy code & continue", sheet).performClick(nil)
            }
            await waitFor { transport.requestCount == (cancelDuringPolling ? 2 : 1) }
            let cancel = try XCTUnwrap(views(sheet.window!.contentView!).compactMap { $0 as? NSButton }
                .first { $0.toolTip == "Cancel GitHub sign-in" })
            XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
            cancel.performClick(nil)
            await waitFor { transport.cancelCount > 0 }
            XCTAssertNil(parent.attachedSheet)
            XCTAssertFalse(success)
            XCTAssertNil(try store.load())
        }
    }

    @MainActor
    func testBrowserFailureOffersRetryWithoutStartingPolling() async throws {
        _ = NSApplication.shared
        let transport = SignInTransport([device])
        let pasteboard = NSPasteboard.withUniqueName()
        let sheet = GitHubSignInController(client: transport.client(store: SignInCredentials()),
            onSignedIn: { _ in XCTFail("Unexpected success") },
            pasteboard: pasteboard, openBrowser: { _ in false })
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { sheet.close(); parent.close(); pasteboard.releaseGlobally(); transport.finish() }
        sheet.present(on: parent)
        await waitFor { (try? self.button("Copy code & continue", sheet).isEnabled) == true }
        try button("Copy code & continue", sheet).performClick(nil)
        XCTAssertTrue(text(sheet).contains("default browser"))
        XCTAssertFalse(try button("Retry", sheet).isHidden)
        XCTAssertEqual(transport.requestCount, 1)
    }
}

private final class SignInCredentials: GitHubCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func load() throws -> Data? { lock.withLock { data } }
    func save(_ data: Data?) throws { lock.withLock { self.data = data } }
}

private final class SignInTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String?]
    private var count = 0
    private var cancelled = 0
    private let id = UUID().uuidString
    init(_ responses: [String?]) { self.responses = responses }
    var requestCount: Int { lock.withLock { count } }
    var cancelCount: Int { lock.withLock { cancelled } }
    func next() -> String? {
        lock.withLock {
            count += 1
            return responses.isEmpty ? #"{"error":"invalid_request"}"# : responses.removeFirst()
        }
    }
    func didCancel() { lock.withLock { cancelled += 1 } }
    func client(store: SignInCredentials) -> GitHubClient {
        SignInProtocol.register(self, id: id)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SignInProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-SignIn": id]
        return GitHubClient(clientID: "test-client", session: URLSession(configuration: config),
                            credentials: store, clock: { Date() }, sleep: { _ in try Task.checkCancellation() })
    }
    func finish() { SignInProtocol.unregister(id) }
}

private final class SignInProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var transports: [String: SignInTransport] = [:]
    private var transport: SignInTransport?
    static func register(_ transport: SignInTransport, id: String) { lock.withLock { transports[id] = transport } }
    static func unregister(_ id: String) { _ = lock.withLock { transports.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        transport = Self.lock.withLock { Self.transports[request.value(forHTTPHeaderField: "X-Test-SignIn") ?? ""] }
        guard let json = transport?.next() else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { transport?.didCancel() }
}
