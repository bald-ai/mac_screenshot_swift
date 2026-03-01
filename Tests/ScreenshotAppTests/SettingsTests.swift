import XCTest
@testable import ScreenshotApp

final class SettingsTests: XCTestCase {
    func testNormalizedClampsAndQuantizesQuality() {
        var settings = Settings.default
        settings.quality = 103
        XCTAssertEqual(settings.normalized().quality, 100)

        settings.quality = 9
        XCTAssertEqual(settings.normalized().quality, 10)

        settings.quality = 97
        XCTAssertEqual(settings.normalized().quality, 95)
    }

    func testNormalizedClampsMaxWidthAndCounterAndPrefix() {
        var settings = Settings.default
        settings.maxWidth = -40
        settings.screenshotCounter = 0
        settings.notePrefix = String(repeating: "A", count: 80)

        let normalized = settings.normalized()
        XCTAssertEqual(normalized.maxWidth, 0)
        XCTAssertEqual(normalized.screenshotCounter, 1)
        XCTAssertEqual(normalized.notePrefix.count, 50)
    }

    func testEnsureTimeOrCounterEnabledUsesExistingCounter() {
        var template = FilenameTemplate(blocks: [
            .init(kind: .staticText, isEnabled: true, text: "Shot"),
            .init(kind: .counter, isEnabled: false)
        ])

        template.ensureTimeOrCounterEnabled()
        let counter = template.blocks.first(where: { $0.kind == .counter })
        XCTAssertEqual(counter?.isEnabled, true)
    }

    func testEnsureTimeOrCounterEnabledAppendsCounterIfMissing() {
        var template = FilenameTemplate(blocks: [
            .init(kind: .staticText, isEnabled: true, text: "Shot"),
            .init(kind: .date, isEnabled: true, format: "yyyy-MM-dd")
        ])

        template.ensureTimeOrCounterEnabled()
        XCTAssertTrue(template.blocks.contains(where: { $0.kind == .counter && $0.isEnabled }))
    }

    func testMoveBlockBoundsAndNoOpCases() {
        var template = FilenameTemplate.defaultTemplate
        let firstID = template.blocks[0].id
        let unknown = UUID()

        template.moveBlock(id: unknown, to: 2)
        XCTAssertEqual(template.blocks[0].id, firstID)

        template.moveBlock(id: firstID, to: 999)
        XCTAssertEqual(template.blocks.last?.id, firstID)
    }

    func testSetBlockEnabledPreservesInvariant() {
        var template = FilenameTemplate(blocks: [
            .init(kind: .time, isEnabled: false, format: "HH.mm.ss"),
            .init(kind: .counter, isEnabled: true),
            .init(kind: .staticText, isEnabled: true, text: "Shot")
        ])
        let counterID = template.blocks.first(where: { $0.kind == .counter })!.id

        template.setBlockEnabled(id: counterID, isEnabled: false)

        XCTAssertTrue(template.blocks.contains(where: { ($0.kind == .time || $0.kind == .counter) && $0.isEnabled }))
    }

    func testMakeFilenameAndComponents() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let template = FilenameTemplate(blocks: [
            .init(kind: .staticText, isEnabled: true, text: "Capture"),
            .init(kind: .date, isEnabled: true, format: "yyyy-MM-dd"),
            .init(kind: .counter, isEnabled: true),
            .init(kind: .time, isEnabled: false, format: "HH.mm.ss")
        ])

        let components = template.makeFilenameComponents(date: date, counter: 7)
        XCTAssertEqual(components.count, 3)
        XCTAssertEqual(components[0], "Capture")
        XCTAssertEqual(components[2], "7")

        let filename = template.makeFilename(date: date, counter: 7)
        XCTAssertTrue(filename.hasPrefix("Capture_"))
        XCTAssertTrue(filename.hasSuffix("_7"))
    }

    func testMakeFilenameFallsBackWhenNoEnabledComponents() {
        let template = FilenameTemplate(blocks: [
            .init(kind: .staticText, isEnabled: false, text: "Ignored")
        ])
        XCTAssertEqual(template.makeFilename(date: .distantPast, counter: 1), "Screenshot")
    }

    func testMakeFilenameComponentsRemainStableAcrossRepeatedCallsWithDifferentFormats() {
        let template = FilenameTemplate(blocks: [
            .init(kind: .date, isEnabled: true, format: "yyyy"),
            .init(kind: .time, isEnabled: true, format: "HH"),
            .init(kind: .date, isEnabled: true, format: "MM")
        ])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = template.makeFilenameComponents(date: date, counter: 1)
        let second = template.makeFilenameComponents(date: date.addingTimeInterval(3600), counter: 1)

        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(first[0], "2023")
        XCTAssertEqual(first[2], "11")
        XCTAssertEqual(second[0], "2023")
        XCTAssertEqual(second[2], "11")
        XCTAssertNotEqual(first[1], second[1])
    }

    func testShortcutsBackwardCompatibleDecodingDefaultsMissingKey() throws {
        let legacy = """
        {
          "screenshotArea": { "keyCode": 20, "modifierFlags": 768 },
          "screenshotFull": { "keyCode": 21, "modifierFlags": 768 }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Shortcuts.self, from: legacy)
        XCTAssertEqual(decoded.screenshotArea.keyCode, 20)
        XCTAssertEqual(decoded.screenshotFull.keyCode, 21)
        XCTAssertEqual(decoded.reopenFinderSelection, Shortcuts.default.reopenFinderSelection)
    }
}
