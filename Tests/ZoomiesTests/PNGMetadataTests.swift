import XCTest
import AppKit
@testable import Zoomies

final class PNGMetadataTests: XCTestCase {
    func testEmbedThenExtractRoundTripsOriginalAndPrompt() throws {
        let burned = try TestSupport.solidImagePNGData(width: 40, height: 20, color: .systemRed)
        let original = try TestSupport.solidImagePNGData(width: 30, height: 15, color: .systemBlue)
        let prompt = "Make the button bigger 🚀 with ünicode"

        let embedded = try XCTUnwrap(PNGMetadata.embed(intoPNG: burned, originalPNG: original, prompt: prompt))
        XCTAssertTrue(PNGMetadata.isPNG(embedded))

        // The embedded result is still a usable PNG of the burned image.
        let reloaded = try XCTUnwrap(NSImage(data: embedded))
        XCTAssertGreaterThan(reloaded.size.width, 0)

        let extracted = try XCTUnwrap(PNGMetadata.extract(fromPNG: embedded))
        XCTAssertEqual(extracted.originalPNG, original, "Embedded original bytes must round-trip exactly.")
        XCTAssertEqual(extracted.prompt, prompt, "Prompt text (incl. unicode) must round-trip exactly.")
    }

    func testExtractReturnsNilWhenChunksMissing() throws {
        let plain = try TestSupport.solidImagePNGData(width: 20, height: 20)
        XCTAssertNil(PNGMetadata.extract(fromPNG: plain))
    }

    func testEmbedReturnsNilForNonPNGContainer() throws {
        let original = try TestSupport.solidImagePNGData(width: 10, height: 10)
        let notPNG = Data("this is not a png".utf8)
        XCTAssertNil(PNGMetadata.embed(intoPNG: notPNG, originalPNG: original, prompt: "x"))
    }

    func testEmbedReturnsNilWhenOriginalIsNotPNG() throws {
        let burned = try TestSupport.solidImagePNGData(width: 10, height: 10)
        let notPNG = Data("nope".utf8)
        XCTAssertNil(PNGMetadata.embed(intoPNG: burned, originalPNG: notPNG, prompt: "x"))
    }

    func testExtractReturnsNilForNonPNG() {
        XCTAssertNil(PNGMetadata.extract(fromPNG: Data("definitely not a png".utf8)))
    }

    func testIsPNGDetectsSignature() throws {
        let png = try TestSupport.solidImagePNGData(width: 8, height: 8)
        XCTAssertTrue(PNGMetadata.isPNG(png))
        XCTAssertFalse(PNGMetadata.isPNG(Data([0x00, 0x01, 0x02])))
        XCTAssertFalse(PNGMetadata.isPNG(Data()))
    }
}
