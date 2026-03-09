import XCTest
import AppKit
@testable import Zoomies

final class ScreenshotServiceCoreLogicTests: XCTestCase {
    func testTargetDisplayReturnsDisplayContainingMouseLocation() {
        let displays = [
            ScreenCaptureTarget(displayID: 101,
                                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                isMain: true),
            ScreenCaptureTarget(displayID: 202,
                                frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                isMain: false)
        ]

        let target = ScreenshotServiceCoreLogic.targetDisplay(for: CGPoint(x: 1500, y: 400),
                                                              displays: displays)

        XCTAssertEqual(target?.displayID, 202)
    }

    func testTargetDisplayFallsBackToMainDisplayWhenMouseIsOutsideAllFrames() {
        let displays = [
            ScreenCaptureTarget(displayID: 101,
                                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                isMain: true),
            ScreenCaptureTarget(displayID: 202,
                                frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                isMain: false)
        ]

        let target = ScreenshotServiceCoreLogic.targetDisplay(for: CGPoint(x: -2000, y: -2000),
                                                              displays: displays)

        XCTAssertEqual(target?.displayID, 101)
    }

    func testTargetDisplayFallsBackToFirstDisplayWhenNoMainDisplayExists() {
        let displays = [
            ScreenCaptureTarget(displayID: 202,
                                frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                isMain: false),
            ScreenCaptureTarget(displayID: 303,
                                frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                isMain: false)
        ]

        let target = ScreenshotServiceCoreLogic.targetDisplay(for: CGPoint(x: 99999, y: 99999),
                                                              displays: displays)

        XCTAssertEqual(target?.displayID, 202)
    }

    func testResizedImageIfNeededKeepsSmallImage() {
        let image = TestSupport.solidImage(width: 80, height: 40)
        let resized = ScreenshotServiceCoreLogic.resizedImageIfNeeded(image, maxWidth: 100)
        XCTAssertEqual(resized.size.width, 80, accuracy: 0.01)
        XCTAssertEqual(resized.size.height, 40, accuracy: 0.01)
    }

    func testResizedImageIfNeededScalesDownLargeImage() {
        let image = TestSupport.solidImage(width: 400, height: 200)
        let resized = ScreenshotServiceCoreLogic.resizedImageIfNeeded(image, maxWidth: 100)
        XCTAssertEqual(resized.size.width, 100, accuracy: 0.01)
        XCTAssertEqual(resized.size.height, 50, accuracy: 0.01)
    }

    func testJpegDataClampsOutOfRangeQuality() {
        let image = TestSupport.solidImage(width: 120, height: 70)
        XCTAssertNotNil(ScreenshotServiceCoreLogic.jpegData(from: image, quality: -30))
        XCTAssertNotNil(ScreenshotServiceCoreLogic.jpegData(from: image, quality: 500))
    }

    func testUniqueScreenshotURLUsesFallbackNameAndSuffixes() {
        let dir = URL(fileURLWithPath: "/tmp")
        let taken = Set(["/tmp/Screenshot.jpg", "/tmp/Screenshot_2.jpg"])
        let url = ScreenshotServiceCoreLogic.uniqueScreenshotURL(in: dir, baseName: "") { taken.contains($0) }
        XCTAssertEqual(url.lastPathComponent, "Screenshot_3.jpg")
    }

    func testLoadTemporaryImageReturnsMissingWhenFileIsNotPresent() {
        let url = URL(fileURLWithPath: "/tmp/missing-image.png")
        let result = ScreenshotServiceCoreLogic.loadTemporaryImage(
            at: url,
            fileExists: { _ in false },
            loadImage: { _ in
                XCTFail("loadImage should not be called when file is missing")
                return nil
            }
        )
        guard case .missing = result else {
            return XCTFail("Expected .missing result")
        }
    }

    func testLoadTemporaryImageReturnsUnreadableWhenLoaderFails() {
        let url = URL(fileURLWithPath: "/tmp/unreadable-image.png")
        let result = ScreenshotServiceCoreLogic.loadTemporaryImage(
            at: url,
            fileExists: { _ in true },
            loadImage: { _ in nil }
        )
        guard case .unreadable = result else {
            return XCTFail("Expected .unreadable result")
        }
    }

    func testLoadTemporaryImageReturnsLoadedWhenImageCanBeRead() {
        let expected = TestSupport.solidImage(width: 32, height: 16)
        let url = URL(fileURLWithPath: "/tmp/readable-image.png")
        let result = ScreenshotServiceCoreLogic.loadTemporaryImage(
            at: url,
            fileExists: { _ in true },
            loadImage: { _ in expected }
        )

        guard case .loaded(let image) = result else {
            return XCTFail("Expected .loaded result")
        }
        XCTAssertEqual(image.size.width, expected.size.width, accuracy: 0.01)
        XCTAssertEqual(image.size.height, expected.size.height, accuracy: 0.01)
    }
}
