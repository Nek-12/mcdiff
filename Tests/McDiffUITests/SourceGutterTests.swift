import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class SourceGutterTests: XCTestCase {
    @MainActor
    func testChangeSignsFollowNumbersAndShareOneUnifiedColumnEvenWithComments() async throws {
        _ = NSApplication.shared
        let file = FileDiff(path: "gutter.swift", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .deletion, text: "", oldNumber: 103, newNumber: nil),
            DiffLine(kind: .addition, text: "", oldNumber: nil, newNumber: 104),
            DiffLine(kind: .context, text: "", oldNumber: 104, newNumber: 105)
        ])], fingerprint: "gutter")
        for layout in [DiffLayout.split, .unified] {
            let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            defer { window.close() }
            view.diffLayout = layout
            view.expanded = [file.path]
            view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
            for _ in 0..<500 where view.isLayoutPending {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(view.isLayoutPending)
            view.layoutSubtreeIfNeeded()
            for hasComments in [false, true] {
                view.commentRange = { _, _, line in hasComments ? line...line : nil }
                let oldCell = try XCTUnwrap(view.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? DiffCell)
                let newCell = layout == .split ? oldCell :
                    try XCTUnwrap(view.table.view(atColumn: 0, row: 2, makeIfNecessary: true) as? DiffCell)
                let old = try signBounds(oldCell, side: .old, layout: layout)
                let new = try signBounds(newCell, side: .new, layout: layout)
                let numbersRight: CGFloat = layout == .split ? 47 : 91
                XCTAssertGreaterThan(old.minX, numbersRight, "Deletion sign must follow every line-number column")
                XCTAssertGreaterThan(new.minX, numbersRight, "Addition sign must follow every line-number column")
                XCTAssertLessThan(old.maxX, view.sourceTextInset - 6)
                XCTAssertLessThan(new.maxX, view.sourceTextInset - 6)
                XCTAssertEqual(old.minX, new.minX, accuracy: 1, "Signs must align regardless of original side")
            }
        }
    }

    @MainActor
    private func signBounds(_ cell: DiffCell, side: DiffSide, layout: DiffLayout) throws -> NSRect {
        let image = NSImage(size: cell.bounds.size, flipped: true) { _ in
            cell.effectiveAppearance.performAsCurrentDrawingAppearance { cell.draw(cell.bounds) }
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let scale = CGFloat(bitmap.pixelsWide) / cell.bounds.width
        let origin = layout == .split && side == .new ? cell.bounds.width / 2 : 0
        let gutterWidth: CGFloat = layout == .split ? 72 : 116
        var pixels: [NSPoint] = []
        for x in Int(origin * scale)..<Int((origin + gutterWidth) * scale) {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.1 else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                if channels.max()! - channels.min()! > 0.25 {
                    pixels.append(NSPoint(x: CGFloat(x) / scale - origin, y: CGFloat(y) / scale))
                }
            }
        }
        XCTAssertFalse(pixels.isEmpty, "The change sign must remain visible when a comment marker exists")
        let left = try XCTUnwrap(pixels.map(\.x).min())
        let right = try XCTUnwrap(pixels.map(\.x).max())
        return NSRect(x: left, y: 0, width: right - left, height: cell.bounds.height)
    }
}
