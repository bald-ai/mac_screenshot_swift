import XCTest
import AppKit
import Carbon
@testable import ScreenshotApp

final class HotKeyServiceTests: XCTestCase {
    func testCarbonModifierFlagsMapsExpectedFlags() {
        let cocoa: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .capsLock]
        let carbon = HotKeyService.carbonModifierFlags(from: cocoa)

        XCTAssertNotEqual(carbon & UInt32(cmdKey), 0)
        XCTAssertNotEqual(carbon & UInt32(shiftKey), 0)
        XCTAssertNotEqual(carbon & UInt32(optionKey), 0)
        XCTAssertNotEqual(carbon & UInt32(controlKey), 0)
        XCTAssertNotEqual(carbon & UInt32(alphaLock), 0)
    }

    func testDescribeShortcutIncludesModifiersAndKeyName() {
        let desc = HotKeyService.describeShortcut(keyCode: UInt32(kVK_ANSI_6),
                                                  carbonFlags: UInt32(cmdKey | shiftKey))
        XCTAssertTrue(desc.contains("⌘"))
        XCTAssertTrue(desc.contains("⇧"))
        XCTAssertTrue(desc.contains("6"))
    }

    func testIsAllowedKeyCodeRecognizesKnownAndUnknown() {
        XCTAssertTrue(HotKeyService.isAllowedKeyCode(UInt16(kVK_ANSI_A)))
        XCTAssertTrue(HotKeyService.isAllowedKeyCode(UInt16(kVK_F12)))
        XCTAssertFalse(HotKeyService.isAllowedKeyCode(0xFFFF))
    }

    func testUpdateShortcutsBeforeRegistrationIsNoOp() {
        let service = HotKeyService()
        service.updateShortcuts(settings: .default)
    }

    func testRegisterAndUpdateShortcutsFlow() {
        let service = HotKeyService()
        var areaCalls = 0
        var fullCalls = 0
        var reopenCalls = 0

        service.registerShortcuts(
            settings: .default,
            areaHandler: { areaCalls += 1 },
            fullHandler: { fullCalls += 1 },
            reopenFinderSelectionHandler: { reopenCalls += 1 }
        )
        service.updateShortcuts(settings: .default)

        XCTAssertEqual(areaCalls, 0)
        XCTAssertEqual(fullCalls, 0)
        XCTAssertEqual(reopenCalls, 0)
    }
}
