import XCTest
import AppKit
@testable import Zoomies

final class EditorCanvasViewTests: XCTestCase {
    private struct Probe { let name: String; let x: Int; let y: Int; let color: NSColor }

    /// Builds an image with four distinct quadrant colors using top-left pixel
    /// indexing (matching NSBitmapImageRep's setColor/colorAt convention).
    private func quadrantImage(width: Int, height: Int) -> (NSImage, [Probe]) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        let green = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        let yellow = NSColor(deviceRed: 1, green: 1, blue: 0, alpha: 1)
        for y in 0..<height {
            for x in 0..<width {
                let c: NSColor
                if x < width / 2 && y < height / 2 { c = red }
                else if x >= width / 2 && y < height / 2 { c = green }
                else if x < width / 2 && y >= height / 2 { c = blue }
                else { c = yellow }
                rep.setColor(c, atX: x, y: y)
            }
        }
        let img = NSImage(size: NSSize(width: width, height: height))
        img.addRepresentation(rep)
        let probes = [
            Probe(name: "top-left", x: width / 4, y: height / 4, color: red),
            Probe(name: "top-right", x: 3 * width / 4, y: height / 4, color: green),
            Probe(name: "bottom-left", x: width / 4, y: 3 * height / 4, color: blue),
            Probe(name: "bottom-right", x: 3 * width / 4, y: 3 * height / 4, color: yellow)
        ]
        return (img, probes)
    }

    private func outputRep(_ image: NSImage) throws -> NSBitmapImageRep {
        try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
    }

    // Core of the fix: passing through the editor must not change pixel dimensions
    // (it used to double them on Retina via NSImage.lockFocus).
    func testCompositeImagePreservesNativeResolution() throws {
        let (image, _) = quadrantImage(width: 100, height: 80)
        let canvas = EditorCanvasView(image: image)

        let rep = try outputRep(canvas.compositeImage())
        XCTAssertEqual(rep.pixelsWide, 100)
        XCTAssertEqual(rep.pixelsHigh, 80)
    }

    // Guards the flipped-coordinate handling in the offscreen render: corners must
    // keep their original colors (an upside-down render would swap them).
    func testCompositeImagePreservesOrientation() throws {
        let (image, probes) = quadrantImage(width: 100, height: 80)
        let canvas = EditorCanvasView(image: image)

        let rep = try outputRep(canvas.compositeImage())
        for probe in probes {
            let actual = try XCTUnwrap(rep.colorAt(x: probe.x, y: probe.y)?.usingColorSpace(.deviceRGB))
            let expected = try XCTUnwrap(probe.color.usingColorSpace(.deviceRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.1, "\(probe.name) red")
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.1, "\(probe.name) green")
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.1, "\(probe.name) blue")
        }
    }
}
