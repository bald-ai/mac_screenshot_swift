import XCTest
@testable import Zoomies

final class BundledResourceLocatorTests: XCTestCase {
    func testResourceURLFindsDirectFileInSearchDirectory() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("screenshot-sound.mp3")
        try Data("sound".utf8).write(to: fileURL, options: .atomic)

        let resolvedURL = BundledResourceLocator.resourceURL(
            named: "screenshot-sound",
            withExtension: "mp3",
            searchDirectories: [root]
        )

        XCTAssertEqual(resolvedURL?.standardizedFileURL, fileURL.standardizedFileURL)
    }

    func testResourceURLFindsFileInsideChildBundle() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let bundleURL = root.appendingPathComponent("Example.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fileURL = bundleURL.appendingPathComponent("screenshot-sound.mp3")
        try Data("sound".utf8).write(to: fileURL, options: .atomic)

        let resolvedURL = BundledResourceLocator.resourceURL(
            named: "screenshot-sound",
            withExtension: "mp3",
            searchDirectories: [root]
        )

        XCTAssertEqual(resolvedURL?.standardizedFileURL, fileURL.standardizedFileURL)
    }
}
