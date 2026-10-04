import AppKit
import XCTest
@testable import McDiff
@testable import McDiffCore

final class HomeLayoutTests: XCTestCase {
    @MainActor
    func testListFillsHomeThroughResumeRemovalAndHiddenResize() async throws {
        _ = NSApplication.shared
        let rows = try (1...100).map {
            PRSummary(pr: try GitHubPR.parse("https://github.com/org/repo/pull/\($0)"),
                      title: "Pull request \($0)", createdAt: Date(), isDraft: false)
        }
        let home = PRHomeController { _, page in
            let start = (page - 1) * PRPage.pageSize
            return PRPage(items: Array(rows[start..<min(rows.count, start + PRPage.pageSize)]),
                          totalCount: rows.count)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbar = NSToolbar(identifier: "home-layout-test")
        window.toolbarStyle = .unified
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800))
        window.contentView = root
        home.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(home.view)
        NSLayoutConstraint.activate([
            home.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            home.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            home.view.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            home.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        home.refresh()
        for _ in 0..<400 {
            if !home.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(home.table.numberOfRows, 100)

        func assertListFillsHome(file: StaticString = #filePath, line: UInt = #line) {
            root.layoutSubtreeIfNeeded()
            let scrollFrame = home.view.convert(home.scroll.bounds, from: home.scroll)
            XCTAssertGreaterThan(home.scroll.frame.height, home.view.bounds.height - 100, file: file, line: line)
            XCTAssertEqual(home.view.bounds.maxY - scrollFrame.maxY, 6, accuracy: 1, file: file, line: line)
            XCTAssertGreaterThan(home.scroll.contentView.bounds.height, home.view.bounds.height - 120, file: file, line: line)
            XCTAssertLessThanOrEqual(home.view.frame.maxY, root.bounds.maxY - root.safeAreaInsets.top,
                                     file: file, line: line)
        }

        assertListFillsHome()
        XCTAssertTrue(home.table.visibleRect.contains(home.table.rect(ofRow: 0)))
        home.resumeTitle = "Current review"
        assertListFillsHome()
        home.scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        home.scroll.reflectScrolledClipView(home.scroll.contentView)
        let origin = home.scroll.contentView.bounds.origin
        home.view.isHidden = true
        window.setContentSize(NSSize(width: 1200, height: 950))
        home.resumeTitle = nil
        home.view.isHidden = false
        assertListFillsHome()
        XCTAssertEqual(home.scroll.contentView.bounds.origin, origin)
        XCTAssertEqual(home.table.numberOfRows, 100)
        for _ in 0..<3 {
            home.resumeTitle = "Another review"
            assertListFillsHome()
            home.resumeTitle = nil
            assertListFillsHome()
            XCTAssertEqual(home.scroll.contentView.bounds.origin, origin)
        }
        home.setUnavailable("Sign in to GitHub")
        assertListFillsHome()
        XCTAssertEqual(home.table.numberOfRows, 0)
        XCTAssertFalse(window.isVisible)
    }
}
