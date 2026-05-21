import XCTest
import AppKit
import ScreenCaptureKit
@testable import Zoomies

final class ScreenshotServiceCoreLogicTests: XCTestCase {
    func testShouldSuppressCaptureFailureAlertForUserDeclinedPermission() {
        let error = NSError(domain: SCStreamErrorDomain,
                            code: Int(SCStreamError.userDeclined.rawValue),
                            userInfo: nil)

        XCTAssertTrue(ScreenshotServiceCoreLogic.shouldSuppressCaptureFailureAlert(error))
    }

    func testShouldNotSuppressCaptureFailureAlertForOtherErrors() {
        let screenCaptureKitError = NSError(domain: SCStreamErrorDomain,
                                            code: Int(SCStreamError.failedToStart.rawValue),
                                            userInfo: nil)
        let appError = NSError(domain: "ScreenshotService",
                               code: -5,
                               userInfo: nil)

        XCTAssertFalse(ScreenshotServiceCoreLogic.shouldSuppressCaptureFailureAlert(screenCaptureKitError))
        XCTAssertFalse(ScreenshotServiceCoreLogic.shouldSuppressCaptureFailureAlert(appError))
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

    func testBitmapRepresentationPreservesBackingPixelDimensions() throws {
        let pointSize = NSSize(width: 200, height: 100)
        let pixelWidth = 400
        let pixelHeight = 200

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelWidth,
                                         pixelsHigh: pixelHeight,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            XCTFail("Failed to create bitmap rep")
            return
        }

        rep.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)

        let bitmap = try XCTUnwrap(ScreenshotServiceCoreLogic.bitmapRepresentation(from: image))
        XCTAssertEqual(bitmap.pixelsWide, pixelWidth)
        XCTAssertEqual(bitmap.pixelsHigh, pixelHeight)
        XCTAssertEqual(bitmap.size.width, pointSize.width, accuracy: 0.01)
        XCTAssertEqual(bitmap.size.height, pointSize.height, accuracy: 0.01)
    }

    func testUniqueScreenshotURLUsesFallbackNameAndSuffixes() {
        let dir = URL(fileURLWithPath: "/tmp")
        let taken = Set(["/tmp/Screenshot.png", "/tmp/Screenshot_2.png"])
        let url = ScreenshotServiceCoreLogic.uniqueScreenshotURL(in: dir, baseName: "") { taken.contains($0) }
        XCTAssertEqual(url.lastPathComponent, "Screenshot_3.png")
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
