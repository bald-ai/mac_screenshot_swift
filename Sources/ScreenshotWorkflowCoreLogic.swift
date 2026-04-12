import Foundation
import CoreGraphics

enum WorkflowFilenameLogic {
    static func editableFilename(_ fullName: String) -> String {
        let ns = fullName as NSString
        let ext = ns.pathExtension
        guard !ext.isEmpty else { return fullName }
        return ns.deletingPathExtension
    }

    static func sanitizeFilename(_ input: String, preservingExtensionOf url: URL) -> String {
        let ext = url.pathExtension

        var base = input
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) {
            base = String(base.dropLast(ext.count + 1))
        }

        let forbidden = CharacterSet(charactersIn: "/:")
        let cleaned = base.components(separatedBy: forbidden).joined()
        var normalizedBase = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty, normalizedBase.lowercased().hasSuffix("." + ext.lowercased()) {
            normalizedBase = String(normalizedBase.dropLast(ext.count + 1))
        }
        let finalBase = normalizedBase.isEmpty ? url.deletingPathExtension().lastPathComponent : normalizedBase

        if ext.isEmpty {
            return finalBase
        }
        return "\(finalBase).\(ext)"
    }

    static func isSameFilename(_ input: String, as url: URL) -> Bool {
        sanitizeFilename(input, preservingExtensionOf: url) == url.lastPathComponent
    }

    static func uniqueURL(forProposedName name: String, in directory: URL, fileExists: (String) -> Bool) -> URL {
        UniqueFileURLLogic.uniqueURL(forProposedName: name, in: directory, fileExists: fileExists)
    }
}

enum WorkflowTextWrapLogic {
    static func wrapText(_ text: String,
                         maxWidth: CGFloat,
                         measure: (String) -> CGFloat) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [""] }

        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return [""] }

        var lines: [String] = []
        var currentLine = ""

        func splitLongWord(_ word: String) -> String {
            var segment = ""
            for char in word {
                let candidate = segment + String(char)
                if measure(candidate) <= maxWidth {
                    segment = candidate
                } else {
                    if !segment.isEmpty {
                        lines.append(segment)
                    }
                    segment = String(char)
                }
            }
            return segment
        }

        for word in words {
            let nextLine = currentLine.isEmpty ? word : "\(currentLine) \(word)"
            if measure(nextLine) <= maxWidth {
                currentLine = nextLine
                continue
            }

            if !currentLine.isEmpty {
                lines.append(currentLine)
                currentLine = ""
            }

            if measure(word) <= maxWidth {
                currentLine = word
            } else {
                currentLine = splitLongWord(word)
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        return lines.isEmpty ? [""] : lines
    }
}
