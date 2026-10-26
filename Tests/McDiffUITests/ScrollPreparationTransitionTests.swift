import AppKit
import McDiffCore
import XCTest
@testable import McDiff

/// Exercises the real animation path without ever presenting a window.
private final class AnimationEligibleWindow: NSWindow {
    override var isVisible: Bool { true }
}

private final class TransitionRecordingLayer: CALayer {
    var fadeRequests = 0

    override func add(_ animation: CAAnimation, forKey key: String?) {
        if let transition = animation as? CATransition, transition.type == .fade {
            fadeRequests += 1
        }
        super.add(animation, forKey: key)
    }
}

final class ScrollPreparationTransitionTests: XCTestCase {
    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw GitError("Scroll preparation did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func fixture() -> (DiffViewport, NSWindow, FileDiff, [PresentedRow]) {
        _ = NSApplication.shared
        let first = FileDiff(path: "first.swift", status: "A", hunks: [
            DiffHunk(header: "", lines: (1...70).map { (number: Int) in
                DiffLine(kind: .addition, text: "let first\(number) = true", oldNumber: nil, newNumber: number)
            })
        ], fingerprint: "first")
        let old = (1...30).map { "let value\($0) = false" }
        var new = old
        new[20] = "let value21 = true"
        let second = FileDiff(path: "second.swift", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .deletion, text: old[20], oldNumber: 21, newNumber: nil),
            DiffLine(kind: .addition, text: new[20], oldNumber: nil, newNumber: 21)
        ], oldRange: 20..<21, newRange: 20..<21)], fingerprint: "second")
        let prepared = DiffPresentation.rows(for: second, oldSource: old.joined(separator: "\n") + "\n",
                                             newSource: new.joined(separator: "\n") + "\n", resolveContext: true)
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        let window = AnimationEligibleWindow(contentRect: view.frame, styleMask: [.titled],
                                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.scroll.contentView.wantsLayer = true
        view.scroll.contentView.layer = TransitionRecordingLayer()
        view.expanded = [first.path, second.path]
        view.setFiles([first, second], presentations: [
            first.path: DiffPresentation.rows(for: first), second.path: DiffPresentation.rows(for: second)
        ])
        view.layoutSubtreeIfNeeded()
        return (view, window, second, prepared)
    }

    @MainActor
    func testFirstVisibleSourcePreparationDoesNotFadeOrMoveScrolledContent() async throws {
        let (view, window, second, prepared) = fixture()
        defer { window.close() }
        var pending: CheckedContinuation<[PresentedRow], Never>?
        view.contexts.resolve = { _ in await withCheckedContinuation { pending = $0 } }
        let header = try XCTUnwrap(view.headerRows[1])
        let position = view.table.rect(ofRow: header).minY
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        try await wait { pending != nil }
        let before = view.scroll.documentVisibleRect.minY
        let layer = try XCTUnwrap(view.scroll.contentView.layer as? TransitionRecordingLayer)
        let fades = layer.fadeRequests
        var resolved = false
        let update = view.contexts.onResolved
        defer { view.contexts.onResolved = update }
        view.contexts.onResolved = { path, rows in
            update?(path, rows)
            XCTAssertEqual(path, second.path)
            XCTAssertEqual(layer.fadeRequests, fades,
                         "Automatic preparation must not fade the viewport during scrolling")
            XCTAssertEqual(view.scroll.documentVisibleRect.minY, before, accuracy: 0.5)
            resolved = true
        }
        pending?.resume(returning: prepared)
        try await wait { resolved }
        XCTAssertEqual(view.focusedFile, 1)
    }

    @MainActor
    func testSourcePreparationKeepsAnimatedNavigationRunningWithoutFade() async throws {
        let (view, window, _, prepared) = fixture()
        defer { window.close() }
        var pending: CheckedContinuation<[PresentedRow], Never>?
        view.contexts.resolve = { _ in await withCheckedContinuation { pending = $0 } }
        view.navigate(to: 1, animated: true)
        try await wait { pending != nil }
        let layer = try XCTUnwrap(view.scroll.contentView.layer as? TransitionRecordingLayer)
        let fades = layer.fadeRequests
        var resolved = false
        let update = view.contexts.onResolved
        defer { view.contexts.onResolved = update }
        view.contexts.onResolved = { path, rows in
            update?(path, rows)
            XCTAssertEqual(layer.fadeRequests, fades)
            XCTAssertEqual(view.focusedFile, 1)
            resolved = true
        }
        pending?.resume(returning: prepared)
        try await wait { resolved }
        let destination = view.table.rect(ofRow: try XCTUnwrap(view.headerRows[1])).minY
        try await wait { abs(view.scroll.documentVisibleRect.minY - destination) < 0.5 }
    }

    @MainActor
    func testExplicitFileExpansionAndLayoutChangeStillFade() throws {
        let (view, window, _, _) = fixture()
        defer { window.close() }
        let layer = try XCTUnwrap(view.scroll.contentView.layer as? TransitionRecordingLayer)
        let fades = layer.fadeRequests
        view.setExpanded(false, file: 1)
        XCTAssertEqual(layer.fadeRequests, fades + 1)
        view.setExpanded(true, file: 1)
        XCTAssertEqual(layer.fadeRequests, fades + 2)
        view.diffLayout = .unified
        XCTAssertEqual(layer.fadeRequests, fades + 3)
    }
}
