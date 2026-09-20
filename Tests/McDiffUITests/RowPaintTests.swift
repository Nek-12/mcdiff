import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class RowPaintTests: XCTestCase {
    @MainActor
    func testTintRunsStopAtContextAndRemainOnTheirOwnSide() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let lines = [
            DiffLine(kind: .addition, text: "", oldNumber: nil, newNumber: 1),
            DiffLine(kind: .addition, text: "", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .context, text: "", oldNumber: 1, newNumber: 3),
            DiffLine(kind: .deletion, text: "", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .deletion, text: "", oldNumber: 3, newNumber: nil)
        ]
        let file = FileDiff(path: "mixed.swift", hunks: [DiffHunk(header: "", lines: lines)], fingerprint: "mixed")
        view.expanded = [file.path]
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        let deadline = Date().addingTimeInterval(20)
        while view.isLayoutPending, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.isLayoutPending)
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: view.table.bounds.width, height: 38 + Style.rowHeight * 5)
        let image = NSImage(size: size, flipped: true) { _ in
            view.table.drawBackground(inClipRect: NSRect(origin: .zero, size: size))
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let scale = CGFloat(bitmap.pixelsHigh) / size.height
        for row in 1...5 {
            let y = Int((38 + (CGFloat(row) - 0.5) * Style.rowHeight) * scale)
            let old = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: y))
            let new = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: y))
            if row < 3 {
                XCTAssertEqual(old.alphaComponent, 0)
                XCTAssertGreaterThan(new.alphaComponent, 0)
            } else if row == 3 {
                XCTAssertEqual(old.alphaComponent, 0)
                XCTAssertEqual(new.alphaComponent, 0)
            } else {
                XCTAssertGreaterThan(old.alphaComponent, 0)
                XCTAssertEqual(new.alphaComponent, 0)
            }
        }
    }

    @MainActor
    func testTallDocumentRowGeometryAtLargeScrollOrigins() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let file = FileDiff(path: "large.swift", hunks: [DiffHunk(header: "", lines: (1...30_050).map { (n: Int) in
            DiffLine(kind: .addition, text: "", oldNumber: nil, newNumber: n)
        })], fingerprint: "large")
        view.expanded = [file.path]
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        let deadline = Date().addingTimeInterval(20)
        while view.isLayoutPending, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.isLayoutPending)
        view.layoutSubtreeIfNeeded()
        for target in [1, 5000, 15000, 30000, 1, 30000, 1, 30000] {
            for offset: CGFloat in [0, 0.25, 0.5, 0.75] {
                let top = 38 + CGFloat(target - 1) * Style.rowHeight + offset
                view.scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
                view.scroll.reflectScrolledClipView(view.scroll.contentView)
                view.table.layoutSubtreeIfNeeded()
                var prior: NSRect?
                let first = view.table.rows(in: view.scroll.documentVisibleRect).location
                for row in (first + 1)...(first + 4) {
                    let cell = try XCTUnwrap(view.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? DiffCell)
                    let screen = cell.convert(cell.bounds, to: view)
                    XCTAssertEqual(cell.bounds.height, Style.rowHeight, accuracy: 0.001)
                    if let prior { XCTAssertEqual(screen.maxY, prior.minY, accuracy: 0.001, "Screen gap at \(row), offset \(offset)") }
                    prior = screen
                }
            }
        }
    }

    @MainActor
    func testAdjacentChangedRowsHaveContinuousTintAtEveryBoundary() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let file = FileDiff(path: "example.swift", hunks: [DiffHunk(header: "", lines: (1...8).map { (n: Int) in
            DiffLine(kind: .addition, text: "", oldNumber: nil, newNumber: n)
        })], fingerprint: "adjacent")
        view.expanded = [file.path]
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        let deadline = Date().addingTimeInterval(20)
        while view.isLayoutPending, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.isLayoutPending)
        view.layoutSubtreeIfNeeded()
        let cells = try (1...8).map { row -> DiffCell in
            try XCTUnwrap(view.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? DiffCell)
        }
        let size = NSSize(width: view.table.bounds.width, height: Style.rowHeight * 8)
        for (scale, offset) in [CGFloat(1), 2].flatMap({ scale in [CGFloat(0), 0.25, 0.5, 0.75, 1].map { (scale, $0) } }) {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            context.cgContext.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            context.cgContext.translateBy(x: 0, y: -38 - offset)
            view.table.drawBackground(inClipRect: NSRect(x: 0, y: 38, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
            for (index, cell) in cells.enumerated() {
                NSGraphicsContext.saveGraphicsState()
                context.cgContext.translateBy(x: 0, y: CGFloat(index) * Style.rowHeight - offset)
                cell.draw(cell.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
            NSGraphicsContext.restoreGraphicsState()
            let x = bitmap.pixelsWide - 40
            let expected = try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 16))
            XCTAssertGreaterThan(expected.alphaComponent, 0)
            XCTAssertEqual(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)?.alphaComponent, 0,
                           "The empty old side must remain transparent")
            for y in 4..<(bitmap.pixelsHigh - 4) {
                let actual = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, "Gap at pixel \(y), offset \(offset) at \(scale)x")
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, "Tint seam at pixel \(y), offset \(offset) at \(scale)x")
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, "Tint seam at pixel \(y), offset \(offset) at \(scale)x")
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, "Tint seam at pixel \(y), offset \(offset) at \(scale)x")
            }
        }
    }
}
