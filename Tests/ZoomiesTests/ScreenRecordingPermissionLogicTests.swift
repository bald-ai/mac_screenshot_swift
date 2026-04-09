import XCTest
@testable import Zoomies

final class ScreenRecordingPermissionLogicTests: XCTestCase {
    func testEnsurePermissionReturnsTrueWhenPreflightAlreadyGranted() {
        var didRequest = false

        let granted = ScreenRecordingPermissionLogic.ensurePermission(
            preflight: { true },
            request: {
                didRequest = true
                return false
            }
        )

        XCTAssertTrue(granted)
        XCTAssertFalse(didRequest)
    }

    func testEnsurePermissionFallsBackToRequestWhenPreflightDenied() {
        var didRequest = false

        let granted = ScreenRecordingPermissionLogic.ensurePermission(
            preflight: { false },
            request: {
                didRequest = true
                return true
            }
        )

        XCTAssertTrue(granted)
        XCTAssertTrue(didRequest)
    }

    func testEnsurePermissionReturnsFalseWhenRequestDenied() {
        let granted = ScreenRecordingPermissionLogic.ensurePermission(
            preflight: { false },
            request: { false }
        )

        XCTAssertFalse(granted)
    }
}
