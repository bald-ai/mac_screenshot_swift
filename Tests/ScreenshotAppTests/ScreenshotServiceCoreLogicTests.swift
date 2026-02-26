import XCTest
import AppKit
@testable import ScreenshotApp

final class ScreenshotServiceCoreLogicTests: XCTestCase {
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

    func testCaptureRectsClampsAndConvertsToPixels() {
        let screen = CGRect(x: 100, y: 100, width: 200, height: 100)
        let selection = CGRect(x: 120, y: 120, width: 50, height: 30)
        let output = ScreenshotServiceCoreLogic.captureRects(rectInScreenPoints: selection,
                                                             screenFrame: screen,
                                                             scale: 2.0)
        guard let output else {
            return XCTFail("Expected capture rects")
        }
        XCTAssertEqual(output.pointRect.width, 50, accuracy: 0.01)
        XCTAssertEqual(output.pointRect.height, 30, accuracy: 0.01)
        XCTAssertEqual(output.pixelRect.width, 100, accuracy: 0.01)
        XCTAssertEqual(output.pixelRect.height, 60, accuracy: 0.01)
    }

    func testCaptureRectsReturnsNilForTooSmallArea() {
        let screen = CGRect(x: 0, y: 0, width: 200, height: 100)
        let selection = CGRect(x: 500, y: 500, width: 20, height: 20)
        XCTAssertNil(ScreenshotServiceCoreLogic.captureRects(rectInScreenPoints: selection,
                                                             screenFrame: screen,
                                                             scale: 1.0))
    }

    func testShouldFallbackToLegacyForKnownErrorPatterns() {
        let osStatus = NSError(domain: NSOSStatusErrorDomain, code: -50)
        XCTAssertTrue(ScreenshotServiceCoreLogic.shouldFallbackToLegacy(osStatus))

        let invalidParam = NSError(domain: "any", code: 123, userInfo: [NSLocalizedDescriptionKey: "Invalid parameter passed"])
        XCTAssertTrue(ScreenshotServiceCoreLogic.shouldFallbackToLegacy(invalidParam))

        let different = NSError(domain: "any", code: 123, userInfo: [NSLocalizedDescriptionKey: "Something else"])
        XCTAssertFalse(ScreenshotServiceCoreLogic.shouldFallbackToLegacy(different))
    }
}
