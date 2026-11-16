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
        try await checkSourcePreparation(layout: .split)
    }

    @MainActor
    func testUnifiedSourcePreparationPreservesPartiallyScrolledHeader() async throws {
        try await checkSourcePreparation(layout: .unified)
    }

    @MainActor
    private func checkSourcePreparation(layout: DiffLayout) async throws {
        let (view, window, second, prepared) = fixture()
        defer { window.close() }
        view.diffLayout = layout
        var pending: CheckedContinuation<[PresentedRow], Never>?
        view.contexts.resolve = { _ in await withCheckedContinuation { pending = $0 } }
        let header = try XCTUnwrap(view.headerRows[1])
        // A partially hidden header is pinned. Background preparation must
        // preserve the source offset, not align the original header to its pin.
        let position = view.table.rect(ofRow: header).minY + 10
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
        try await wait { !view.isLayoutPending }
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, before, accuracy: 0.5,
                       "Deferred row measurement must preserve the scrolling position too")
        XCTAssertEqual(view.focusedFile, 1)
    }

    @MainActor
    func testRapidBoundaryReversalsDuringFirstPreparation() async throws {
        for layout in [DiffLayout.split, .unified] {
            for wrap in [false, true] {
                let (view, window, second, prepared) = fixture()
                defer { window.close() }
                let large = FileDiff(path: "large.swift", status: "A", hunks: [
                    DiffHunk(header: "", lines: (1...1500).map { (number: Int) in
                        DiffLine(kind: .addition,
                                 text: "let value\(number) = \"" + String(repeating: "wrapped text ", count: 12) + "\"",
                                 oldNumber: nil, newNumber: number)
                    })
                ], fingerprint: "large")
                let reviewed = FileDiff(path: "reviewed.swift", hunks: [], fingerprint: "reviewed")
                view.diffLayout = layout
                view.softWrap = wrap
                view.isReviewed = { $0.path == reviewed.path }
                view.expanded = [large.path, second.path]
                var pending: CheckedContinuation<[PresentedRow], Never>?
                view.contexts.resolve = { file in
                    if file.path == second.path {
                        return await withCheckedContinuation { pending = $0 }
                    }
                    return DiffPresentation.rows(for: file)
                }
                view.setFiles([large, reviewed, second], presentations: [
                    large.path: DiffPresentation.rows(for: large),
                    second.path: DiffPresentation.rows(for: second)
                ])
                view.layoutSubtreeIfNeeded()
                try await wait { !view.isLayoutPending }
                let boundary = view.table.rect(ofRow: try XCTUnwrap(view.headerRows[2])).minY
                func scroll(_ position: CGFloat) {
                    view.scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
                    view.scroll.reflectScrolledClipView(view.scroll.contentView)
                    view.table.layoutSubtreeIfNeeded()
                }
                scroll(boundary + 10)
                try await wait { pending != nil }
                // Cross the reviewed header and unchanged-section controls in
                // both directions while first-time source work remains pending.
                let middle = try XCTUnwrap(view.rows.firstIndex { $0.line(on: .new)?.newNumber == 750 })
                let deepPosition = view.table.rect(ofRow: middle).minY + 7
                for position in [boundary + 100, deepPosition, boundary + 70,
                                 deepPosition + 800, boundary + 10] {
                    scroll(position)
                }
                let before = view.scroll.documentVisibleRect.minY
                let visible = view.table.rows(in: view.scroll.documentVisibleRect).location
                let identity = view.rows[visible]
                let inset = before - view.table.rect(ofRow: visible).minY
                var resolved = false
                let update = view.contexts.onResolved
                view.contexts.onResolved = { path, rows in
                    update?(path, rows)
                    if path == second.path { resolved = true }
                }
                pending?.resume(returning: prepared)
                try await wait { resolved && !view.isLayoutPending }
                let current = view.table.rows(in: view.scroll.documentVisibleRect).location
                XCTAssertTrue(view.rows[current].sameLocation(as: identity))
                XCTAssertEqual(view.scroll.documentVisibleRect.minY - view.table.rect(ofRow: current).minY,
                               inset, accuracy: 0.5)
                // Absolute document coordinates may change as wrapped rows
                // above are measured; source identity and screen offset must not.
                XCTAssertTrue(view.rows.contains { if case .context = $0.content { return true }; return false })
            }
        }
    }

    @MainActor
    func testSourcePreparationKeepsVisibleSourceWhenEmptyTailDisappears() async throws {
        try await checkDisappearingTail(lastVisible: false)
    }

    @MainActor
    func testSourcePreparationKeepsVisibleSourceWhenLastVisibleControlDisappears() async throws {
        try await checkDisappearingTail(lastVisible: true)
    }

    @MainActor
    private func checkDisappearingTail(lastVisible: Bool) async throws {
        let configurations: [(DiffLayout, Bool)] = [(.split, false), (.unified, false), (.split, true), (.unified, true)]
        for (layout, wrap) in configurations {
            let (view, window, second, _) = fixture()
            defer { window.close() }
            let lines = (1...199).map { (number: Int) in
                DiffLine(kind: .context, text: "let value\(number) = \"" + String(repeating: "wrapped text ", count: 12) + "\"",
                         oldNumber: number, newNumber: number)
            }
            let oldEnd = DiffLine(kind: .deletion, text: "let end = false", oldNumber: 200, newNumber: nil)
            let newEnd = DiffLine(kind: .addition, text: "let end = true", oldNumber: nil, newNumber: 200)
            let file = FileDiff(path: "long.swift", hunks: [
                DiffHunk(header: "", lines: lines + [oldEnd, newEnd], oldRange: 0..<200, newRange: 0..<200)
            ], fingerprint: "long")
            let oldSource = (lines.map(\.text) + [oldEnd.text]).joined(separator: "\n") + "\n"
            let newSource = (lines.map(\.text) + [newEnd.text]).joined(separator: "\n") + "\n"
            let prepared = DiffPresentation.rows(for: file, oldSource: oldSource, newSource: newSource,
                                                resolveContext: true)
            view.diffLayout = layout
            view.softWrap = wrap
            view.expanded = [file.path, second.path]
            var pending: CheckedContinuation<[PresentedRow], Never>?
            view.contexts.resolve = { value in
                if value.path == file.path {
                    return await withCheckedContinuation { pending = $0 }
                }
                return DiffPresentation.rows(for: value)
            }
            view.setFiles([file, second], presentations: [
                file.path: DiffPresentation.rows(for: file),
                second.path: DiffPresentation.rows(for: second)
            ])
            view.layoutSubtreeIfNeeded()
            try await wait { pending != nil && !view.isLayoutPending }
            let tail = try XCTUnwrap(view.rows.firstIndex { row in
                guard row.file == 0 else { return false }
                if case .context = row.content { return true }; return false
            })
            let tailRect = view.table.rect(ofRow: tail)
            let position = lastVisible ? tailRect.midY - view.scroll.documentVisibleRect.height : tailRect.minY + 3
            view.scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
            view.scroll.reflectScrolledClipView(view.scroll.contentView)
            let visible = view.table.rows(in: view.scroll.documentVisibleRect)
            if lastVisible { XCTAssertEqual(NSMaxRange(visible) - 1, tail) }
            let original = try lastVisible ? visible.location : XCTUnwrap(view.rows.firstIndex {
                $0.file == 1 && $0.line(on: .new)?.newNumber == 21
            })
            let identity = view.rows[original]
            XCTAssertNotNil(identity.line(on: .new)?.newNumber)
            let inset = view.table.rect(ofRow: original).minY - view.scroll.documentVisibleRect.minY
            pending?.resume(returning: prepared)
            try await wait {
                if case .ready = view.contexts.preparation(path: file.path) { return !view.isLayoutPending }
                return false
            }
            let current = try XCTUnwrap(view.rows.firstIndex { $0.sameLocation(as: identity) })
            XCTAssertEqual(view.table.rect(ofRow: current).minY - view.scroll.documentVisibleRect.minY,
                           inset, accuracy: 0.5,
                           "A disappearing tail must preserve the visible source")
            let painted = try XCTUnwrap(view.table.rowView(atRow: current, makeIfNecessary: false))
            XCTAssertEqual(view.table.convert(painted.bounds, from: painted).minY - view.scroll.documentVisibleRect.minY,
                           inset, accuracy: 0.5)
        }
    }

    @MainActor
    func testDelayedUnchangedLinesKeepCurrentSourceAfterScrollingAway() async throws {
        let configurations: [(DiffLayout, Bool)] = [(.split, false), (.unified, false), (.split, true), (.unified, true)]
        for (layout, wrap) in configurations {
            let (view, window, _, _) = fixture()
            defer { window.close() }
            let file = FileDiff(path: "long.swift", hunks: [
                DiffHunk(header: "", lines: (101...300).map { (number: Int) in
                    DiffLine(kind: .context, text: "let value\(number) = \"" + String(repeating: "wrapped text ", count: 12) + "\"",
                             oldNumber: number, newNumber: number)
                }, oldRange: 100..<300, newRange: 100..<300)
            ], fingerprint: "long")
            view.diffLayout = layout
            view.softWrap = wrap
            view.expanded = [file.path]
            view.contexts.resolve = nil
            view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
            view.layoutSubtreeIfNeeded()
            try await wait { !view.isLayoutPending }
            let section = try XCTUnwrap(file.unchangedSections.first)
            var pending: CheckedContinuation<[DiffPair], Never>?
            view.contexts.load = { _, _ in
                await withCheckedContinuation { pending = $0 }
            }
            view.contexts.toggle(file: file, section: section)
            try await wait { pending != nil }
            let source = try XCTUnwrap(view.rows.firstIndex { $0.line(on: .new)?.newNumber == 220 })
            view.scroll.contentView.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: source).minY + 7))
            view.scroll.reflectScrolledClipView(view.scroll.contentView)
            let identity = view.rows[source]
            let inset = view.scroll.documentVisibleRect.minY - view.table.rect(ofRow: source).minY
            pending?.resume(returning: (1...100).map { (number: Int) in
                let line = DiffLine(kind: .context, text: "let value\(number) = \"" + String(repeating: "wrapped text ", count: 12) + "\"",
                                    oldNumber: number, newNumber: number)
                return DiffPair(old: line, new: line)
            })
            try await wait {
                if case .expanded = view.contexts.state(path: file.path, section: section.id) {
                    return !view.isLayoutPending
                }
                return false
            }
            let current = view.table.rows(in: view.scroll.documentVisibleRect).location
            XCTAssertTrue(view.rows[current].sameLocation(as: identity),
                          "Finishing an offscreen section must preserve the source being read")
            let relocated = try XCTUnwrap(view.rows.firstIndex { $0.sameLocation(as: identity) })
            XCTAssertEqual(view.scroll.documentVisibleRect.minY - view.table.rect(ofRow: relocated).minY,
                           inset, accuracy: 0.5)
            let painted = try XCTUnwrap(view.table.rowView(atRow: relocated, makeIfNecessary: false))
            XCTAssertEqual(view.scroll.documentVisibleRect.minY - view.table.convert(painted.bounds, from: painted).minY,
                           inset, accuracy: 0.5)
        }
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
