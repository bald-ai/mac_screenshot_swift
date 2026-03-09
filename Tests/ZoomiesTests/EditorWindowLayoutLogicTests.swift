import XCTest
import AppKit
@testable import Zoomies

final class EditorWindowLayoutLogicTests: XCTestCase {
    func testMaximumContentSizeUsesNinetyPercentOfVisibleFrame() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 2000, height: 1000)

        let size = EditorWindowLayoutLogic.maximumContentSize(
            visibleFrame: visibleFrame,
            minContentSize: NSSize(width: 580, height: 250)
        )

        XCTAssertEqual(size.width, 1800, accuracy: 0.01)
        XCTAssertEqual(size.height, 900, accuracy: 0.01)
    }

    func testMaximumContentSizeFallsBackWhenVisibleFrameIsMissing() {
        let size = EditorWindowLayoutLogic.maximumContentSize(
            visibleFrame: nil,
            minContentSize: NSSize(width: 580, height: 250)
        )

        XCTAssertEqual(size.width, 1400, accuracy: 0.01)
        XCTAssertEqual(size.height, 900, accuracy: 0.01)
    }

    func testMaximumContentSizeNeverDropsBelowMinimum() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 400, height: 200)

        let size = EditorWindowLayoutLogic.maximumContentSize(
            visibleFrame: visibleFrame,
            minContentSize: NSSize(width: 580, height: 250)
        )

        XCTAssertEqual(size.width, 580, accuracy: 0.01)
        XCTAssertEqual(size.height, 250, accuracy: 0.01)
    }

    func testMakeLayoutKeepsFitScaleAtOneWhenImageFits() {
        let layout = EditorWindowLayoutLogic.makeLayout(
            EditorWindowLayoutInput(imagePointSize: NSSize(width: 800, height: 500),
                                    maxContentSize: NSSize(width: 1400, height: 900),
                                    minContentSize: NSSize(width: 580, height: 250),
                                    chromeSize: NSSize(width: 24, height: 120),
                                    wasResized: false,
                                    autoZoomFillRatio: 0.90,
                                    maxAutoUserZoom: 2.0)
        )

        XCTAssertEqual(layout.fitScale, 1.0, accuracy: 0.0001)
    }

    func testMakeLayoutReducesFitScaleWhenImageExceedsDynamicCap() {
        let layout = EditorWindowLayoutLogic.makeLayout(
            EditorWindowLayoutInput(imagePointSize: NSSize(width: 1700, height: 900),
                                    maxContentSize: NSSize(width: 1200, height: 700),
                                    minContentSize: NSSize(width: 580, height: 250),
                                    chromeSize: NSSize(width: 24, height: 120),
                                    wasResized: false,
                                    autoZoomFillRatio: 0.90,
                                    maxAutoUserZoom: 2.0)
        )

        XCTAssertLessThan(layout.fitScale, 1.0)
    }

    func testMakeLayoutReturnsZeroPaddingWhenImageWasResized() {
        let layout = EditorWindowLayoutLogic.makeLayout(
            EditorWindowLayoutInput(imagePointSize: NSSize(width: 800, height: 500),
                                    maxContentSize: NSSize(width: 1400, height: 900),
                                    minContentSize: NSSize(width: 580, height: 250),
                                    chromeSize: NSSize(width: 24, height: 120),
                                    wasResized: true,
                                    autoZoomFillRatio: 0.90,
                                    maxAutoUserZoom: 2.0)
        )

        XCTAssertEqual(layout.totalPadding, 0.0, accuracy: 0.0001)
    }

    func testMakeLayoutAutoZoomsSmallImagesWithoutExceedingMax() {
        let layout = EditorWindowLayoutLogic.makeLayout(
            EditorWindowLayoutInput(imagePointSize: NSSize(width: 120, height: 80),
                                    maxContentSize: NSSize(width: 1400, height: 900),
                                    minContentSize: NSSize(width: 580, height: 250),
                                    chromeSize: NSSize(width: 24, height: 120),
                                    wasResized: false,
                                    autoZoomFillRatio: 0.90,
                                    maxAutoUserZoom: 2.0)
        )

        XCTAssertGreaterThan(layout.defaultUserZoomFactor, 1.0)
        XCTAssertLessThanOrEqual(layout.defaultUserZoomFactor, 2.0)
    }
}
