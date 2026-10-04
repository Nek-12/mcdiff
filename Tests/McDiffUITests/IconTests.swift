import AppKit
import XCTest
@testable import McDiff

final class IconTests: XCTestCase {
    @MainActor
    func testCatalogSymbolsExistAndSupportAccentPalettes() throws {
        for symbol in Icons.Symbol.allCases {
            let image = Icons.image(symbol)
            XCTAssertGreaterThan(image.size.width, 0, symbol.rawValue)
            XCTAssertGreaterThan(image.size.height, 0, symbol.rawValue)
            XCTAssertTrue(image.isTemplate, symbol.rawValue)
            XCTAssertNotNil(image.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])), symbol.rawValue)
        }
    }

    @MainActor
    func testSearchUsesSharedSymbolOnNativeCell() throws {
        let field = NSSearchField()
        Icons.configureSearchField(field)
        let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
        XCTAssertTrue(cell.searchButtonCell?.image === Icons.image(.search))
        XCTAssertNotNil(cell.searchButtonCell?.action)
    }

    @MainActor
    func testEveryDrawnSymbolRendersOffscreenInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for symbol in Icons.Symbol.allCases {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                appearance.performAsCurrentDrawingAppearance {
                    Icons.draw(symbol, in: NSRect(x: 4, y: 4, width: 16, height: 16), color: .labelColor)
                }
                NSGraphicsContext.restoreGraphicsState()
                let hasInk = (0..<24).contains { y in
                    (0..<24).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
                }
                XCTAssertTrue(hasInk, "\(symbol.rawValue), \(name.rawValue)")
            }
        }
    }
}
