import XCTest
import AppKit
@testable import Zoomies

final class FloatingPanelPositionLogicTests: XCTestCase {
    func testCenteredOriginUsesVisibleFrameCenter() {
        let origin = FloatingPanelPositionLogic.centeredOrigin(
            windowSize: NSSize(width: 410, height: 215),
            in: NSRect(x: 0, y: 0, width: 1440, height: 875)
        )

        XCTAssertEqual(origin.x, 515)
        XCTAssertEqual(origin.y, 330)
    }
}
