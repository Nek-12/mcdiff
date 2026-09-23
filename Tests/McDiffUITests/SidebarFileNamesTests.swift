import XCTest
@testable import McDiff

final class SidebarFileNamesTests: XCTestCase {
    func testWalksBackwardToFirstDifferingDirectory() {
        let paths = [
            "src/wearOsMain/kotlin/com/example/auth.kt",
            "src/androidMain/kotlin/com/example/auth.kt",
            "src/commonMain/kotlin/com/example/profile.kt",
            "client/config.json", "server/config.json"
        ]
        XCTAssertEqual(SidebarFileNames.labels(for: paths), [
            paths[0]: "wearOsMain/…/auth.kt",
            paths[1]: "androidMain/…/auth.kt",
            paths[2]: "profile.kt",
            paths[3]: "client/config.json",
            paths[4]: "server/config.json"
        ])
    }

    func testMultipleDuplicatesUnequalDepthAndRootFiles() {
        let paths = ["one/shared/auth.kt", "two/shared/auth.kt", "other/auth.kt", "auth.kt"]
        let labels = SidebarFileNames.labels(for: paths)
        XCTAssertEqual(labels[paths[0]], "one/…/auth.kt")
        XCTAssertEqual(labels[paths[1]], "two/…/auth.kt")
        XCTAssertEqual(labels[paths[2]], "other/auth.kt")
        XCTAssertEqual(labels[paths[3]], "auth.kt")
        XCTAssertEqual(labels, SidebarFileNames.labels(for: paths.reversed()))
    }

    func testCollapsedLabelsRemainDistinctEvenWithRepeatedDirectoryNames() {
        let paths = ["left/a/shared/file.kt", "left/b/shared/file.kt",
                     "right/a/other/file.kt", "right/c/other/file.kt"]
        let labels = SidebarFileNames.labels(for: paths)
        XCTAssertEqual(Set(labels.values).count, paths.count)
        XCTAssertEqual(labels[paths[0]], "left/a/…/file.kt")
        XCTAssertEqual(labels[paths[2]], "right/a/…/file.kt")
    }

    func testRepeatedRootNamesRetainEnoughOfTheOmittedPath() {
        let paths = ["a/x/same/file.kt", "b/x/same/file.kt",
                     "a/y/same/file.kt", "c/y/same/file.kt"]
        let labels = SidebarFileNames.labels(for: paths)
        XCTAssertEqual(labels[paths[0]], "a/x/…/file.kt")
        XCTAssertEqual(labels[paths[2]], "a/y/…/file.kt")
        XCTAssertEqual(Set(labels.values).count, paths.count)
    }
}
