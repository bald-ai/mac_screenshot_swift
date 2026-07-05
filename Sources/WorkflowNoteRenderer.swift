import AppKit

struct WorkflowPreparedNote: Equatable {
    let identity: String
    let rendered: String
}

enum WorkflowNoteRenderer {
    private static let maxNoteLength = 1000

    static func prepareNoteText(_ rawText: String, settings: Settings) -> WorkflowPreparedNote? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let identity = String(trimmed.prefix(maxNoteLength))
        var rendered = identity

        if settings.notePrefixEnabled {
            let prefix = settings.notePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                rendered = prefix + " " + identity
            }
        }

        return WorkflowPreparedNote(identity: identity, rendered: rendered)
    }

    static func burn(note text: String, into image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let baseWidth = CGFloat(cgImage.width)
        let baseHeight = CGFloat(cgImage.height)
        let minWidth: CGFloat = 400
        let effectiveWidth = max(baseWidth, minWidth)

        let fontSize = max(12, baseWidth * 0.04)
        let padding = max(8, baseWidth * 0.02)
        let lineHeight = fontSize * 1.4

        let font = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]

        let availableTextWidth = effectiveWidth - padding * 2
        let lines = wrapText(text, maxWidth: availableTextWidth, attributes: attributes)
        let noteHeight = ceil(CGFloat(lines.count) * lineHeight + padding * 2)

        let outputSize = NSSize(width: effectiveWidth, height: baseHeight + noteHeight)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(effectiveWidth),
                                         pixelsHigh: Int(baseHeight + noteHeight),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            return nil
        }
        rep.size = outputSize

        let result = NSImage(size: outputSize)
        result.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high

            if effectiveWidth > baseWidth {
                NSColor(calibratedWhite: 0.95, alpha: 1.0).setFill()
                NSRect(origin: .zero, size: outputSize).fill()
            }

            let imageX = (effectiveWidth - baseWidth) / 2
            let baseImage = NSImage(cgImage: cgImage, size: NSSize(width: baseWidth, height: baseHeight))
            baseImage.draw(in: NSRect(x: imageX, y: noteHeight, width: baseWidth, height: baseHeight),
                           from: .zero,
                           operation: .sourceOver,
                           fraction: 1.0)

            let noteRect = NSRect(x: 0, y: 0, width: effectiveWidth, height: noteHeight)
            NSColor.white.setFill()
            noteRect.fill()

            for (index, line) in lines.enumerated() {
                let topY = noteHeight - padding - CGFloat(index) * lineHeight
                let lineRect = NSRect(x: padding,
                                      y: topY - lineHeight,
                                      width: availableTextWidth,
                                      height: lineHeight)
                (line as NSString).draw(with: lineRect,
                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                        attributes: attributes)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        return result
    }

    private static func wrapText(_ text: String,
                                 maxWidth: CGFloat,
                                 attributes: [NSAttributedString.Key: Any]) -> [String] {
        WorkflowTextWrapLogic.wrapText(text, maxWidth: maxWidth) { value in
            (value as NSString).size(withAttributes: attributes).width
        }
    }
}
