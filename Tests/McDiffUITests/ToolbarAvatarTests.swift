import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class ToolbarAvatarTests: XCTestCase {
    @MainActor
    func testAvatarIsCircularAndKeepsItsColor() throws {
        let avatar = ReviewWindowController.toolbarAvatar(from: sourceImage())
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(
            avatar.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        XCTAssertFalse(avatar.isTemplate)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0)
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
            .usingColorSpace(.deviceRGB)
        XCTAssertEqual(try XCTUnwrap(center).blueComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(center).alphaComponent, 1)
    }

    @MainActor
    func testAvatarRendersAt24PointsWithoutGrowingNativeGlassButton() throws {
        _ = NSApplication.shared
        let controller = ReviewWindowController(github: GitHubClient(
            clientID: "test", credentials: AvatarCredentials()))
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "account" })
        let avatar = ReviewWindowController.toolbarAvatar(from: sourceImage())
        item.image = avatar
        let chrome = try XCTUnwrap(window.contentView?.superview)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            chrome.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(descendants(chrome).compactMap { $0 as? NSButton }
                .first { $0.image === avatar })
            XCTAssertNil(item.view, "The system must generate the toolbar button.")
            XCTAssertTrue(item.isBordered)
            XCTAssertTrue(button.isBordered)
            XCTAssertEqual(button.frame.size, NSSize(width: 36, height: 36))
            let imageRect = try XCTUnwrap(button.cell).imageRect(forBounds: button.bounds)
            XCTAssertEqual(imageRect.size, NSSize(width: 24, height: 24))
            XCTAssertEqual(imageRect.midX, button.bounds.midX)
            XCTAssertEqual(imageRect.midY, button.bounds.midY)
            XCTAssertFalse(window.isVisible)
        }
    }

    @MainActor
    private func sourceImage() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1).setFill()
            rect.fill()
            return true
        }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private struct AvatarCredentials: GitHubCredentialStore {
    func load() throws -> Data? { nil }
    func save(_ data: Data?) throws {}
}
