import XCTest
import AppKit
@testable import Zoomies

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

    func testScreenCaptureRectFlipsToDisplayTopLeftCoordinates() {
        let result = ScreenshotServiceCoreLogic.screenCaptureRect(
            rectInScreenPoints: CGRect(x: 100, y: 50, width: 200, height: 100),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            scale: 2
        )

        XCTAssertEqual(result?.pointRect, CGRect(x: 100, y: 750, width: 200, height: 100))
        XCTAssertEqual(result?.pixelRect, CGRect(x: 200, y: 1500, width: 400, height: 200))
    }

    func testScreenCaptureRectAccountsForSecondaryDisplayOrigin() {
        let result = ScreenshotServiceCoreLogic.screenCaptureRect(
            rectInScreenPoints: CGRect(x: 1500, y: 50, width: 200, height: 100),
            screenFrame: CGRect(x: 1440, y: 0, width: 1280, height: 800),
            scale: 2
        )

        XCTAssertEqual(result?.pointRect, CGRect(x: 60, y: 650, width: 200, height: 100))
        XCTAssertEqual(result?.pixelRect, CGRect(x: 120, y: 1300, width: 400, height: 200))
    }

    func testScreenCaptureRectClampsSelectionToDisplayBounds() {
        let result = ScreenshotServiceCoreLogic.screenCaptureRect(
            rectInScreenPoints: CGRect(x: -20, y: -20, width: 100, height: 100),
            screenFrame: CGRect(x: 0, y: 0, width: 80, height: 80),
            scale: 2
        )

        XCTAssertEqual(result?.pointRect, CGRect(x: 0, y: 0, width: 80, height: 80))
        XCTAssertEqual(result?.pixelRect, CGRect(x: 0, y: 0, width: 160, height: 160))
    }

    func testScreenCaptureRectReturnsNilWhenSelectionFallsOutsideDisplay() {
        let result = ScreenshotServiceCoreLogic.screenCaptureRect(
            rectInScreenPoints: CGRect(x: 500, y: 500, width: 50, height: 50),
            screenFrame: CGRect(x: 0, y: 0, width: 80, height: 80),
            scale: 2
        )

        XCTAssertNil(result)
    }
}
