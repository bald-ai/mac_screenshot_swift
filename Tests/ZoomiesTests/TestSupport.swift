import XCTest
import AppKit

enum TestSupport {
    static func makeTemporaryDirectory(function: StaticString = #function) throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let name = "mac_screenshot_swift_tests_\(function)_\(UUID().uuidString)"
        let directory = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func removeIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func solidImage(width: CGFloat = 100, height: CGFloat = 60, color: NSColor = .systemBlue) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    static func solidImagePNGData(width: CGFloat = 100,
                                  height: CGFloat = 60,
                                  color: NSColor = .systemBlue) throws -> Data {
        let image = solidImage(width: width, height: height, color: color)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "TestSupport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode test PNG image"])
        }
        return data
    }

    static func writeSolidImagePNG(to url: URL,
                                   width: CGFloat = 100,
                                   height: CGFloat = 60,
                                   color: NSColor = .systemBlue) throws {
        let data = try solidImagePNGData(width: width, height: height, color: color)
        try data.write(to: url, options: .atomic)
    }
}
