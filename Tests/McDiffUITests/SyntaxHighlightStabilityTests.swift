import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class SyntaxHighlightStabilityTests: XCTestCase {
    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw GitError("Syntax highlighting did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func testExpandingAndScrollingIntoAnotherFileKeepsVisibleSyntaxColors() async throws {
        _ = NSApplication.shared
        let stable = FileDiff(path: "stable.go", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .addition, text: "func stable() { return }", oldNumber: nil, newNumber: 1)
        ])], fingerprint: "stable-go")
        let original = (1...25).map { "export const value\($0) = false;" }
        var updated = original
        updated[20] = "export const value21 = true;"
        let changed = FileDiff(path: "types.ts", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .deletion, text: original[20], oldNumber: 21, newNumber: nil),
            DiffLine(kind: .addition, text: updated[20], oldNumber: nil, newNumber: 21)
        ], oldRange: 20..<21, newRange: 20..<21)], fingerprint: "types")
        let files = [stable, changed]
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.softWrap = true
        view.diffLayout = .unified
        view.expanded = [stable.path]
        var resolutions = 0
        view.contexts.resolve = { file in
            resolutions += 1
            return DiffPresentation.rows(for: file, oldSource: original.joined(separator: "\n") + "\n",
                                         newSource: updated.joined(separator: "\n") + "\n", resolveContext: true)
        }
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map {
            ($0.path, DiffPresentation.rows(for: $0))
        }))
        view.layoutSubtreeIfNeeded()
        try await wait { view.richText(file: stable, side: .new, line: 1) != nil }
        let color = try XCTUnwrap(view.richText(file: stable, side: .new, line: 1))
        let resolved = view.contexts.onResolved
        defer { view.contexts.onResolved = resolved }
        view.contexts.onResolved = { path, rows in
            resolved?(path, rows)
            XCTAssertEqual(view.richText(file: stable, side: .new, line: 1), color)
        }
        view.setExpanded(true, file: 1)
        try await wait { view.richText(file: changed, side: .new, line: 25) != nil }
        for layout in [DiffLayout.split, .unified] {
            view.diffLayout = layout
            for expanded in [false, true, false, true] {
                view.setExpanded(expanded, file: 1)
                view.layoutSubtreeIfNeeded()
                view.scroll.contentView.scroll(to: NSPoint(x: 0, y: 10))
                view.scroll.reflectScrolledClipView(view.scroll.contentView)
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertEqual(view.richText(file: stable, side: .new, line: 1), color)
            }
        }
        XCTAssertEqual(resolutions, 1)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testContextExpansionAndCollapseNeverRemoveExistingSyntaxColors() async throws {
        _ = NSApplication.shared
        let stable = FileDiff(path: "stable.swift", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .addition, text: "let stable = true", oldNumber: nil, newNumber: 1)
        ])], fingerprint: "stable")
        let changed = FileDiff(path: "changed.swift", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .deletion, text: "let changed = false", oldNumber: 21, newNumber: nil),
            DiffLine(kind: .addition, text: "let changed = true", oldNumber: nil, newNumber: 21)
        ], oldRange: 20..<21, newRange: 20..<21)], fingerprint: "changed")
        let files = [stable, changed]
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.diffLayout = .unified
        view.expanded = Set(files.map(\.path))
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map {
            ($0.path, DiffPresentation.rows(for: $0))
        }))
        view.layoutSubtreeIfNeeded()
        try await wait {
            view.richText(file: stable, side: .new, line: 1) != nil &&
            view.richText(file: changed, side: .new, line: 21) != nil
        }
        let stableColor = try XCTUnwrap(view.richText(file: stable, side: .new, line: 1))
        let changedColor = try XCTUnwrap(view.richText(file: changed, side: .new, line: 21))
        let section = try XCTUnwrap(changed.unchangedSections.first)
        view.contexts.load = { _, section in
            (1...(section.count ?? 0)).map { number in
                let line = DiffLine(kind: .context, text: "let context\(number) = true", oldNumber: number, newNumber: number)
                return DiffPair(old: line, new: line)
            }
        }
        var transitions = 0
        let update = view.contexts.onChange
        defer { view.contexts.onChange = update }
        view.contexts.onChange = { path, section in
            update?(path, section)
            transitions += 1
            XCTAssertEqual(view.richText(file: stable, side: .new, line: 1), stableColor)
            XCTAssertEqual(view.richText(file: changed, side: .new, line: 21), changedColor)
        }
        view.contexts.toggle(file: changed, section: section)
        try await wait { view.richText(file: changed, side: .new, line: 10) != nil }
        XCTAssertGreaterThanOrEqual(transitions, 2)
        view.contexts.toggle(file: changed, section: section)
        XCTAssertEqual(view.richText(file: stable, side: .new, line: 1), stableColor)
        XCTAssertEqual(view.richText(file: changed, side: .new, line: 21), changedColor)
        XCTAssertFalse(window.isVisible)
    }
}
