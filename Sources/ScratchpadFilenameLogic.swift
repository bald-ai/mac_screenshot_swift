import Foundation

/// Pure filename logic for the scratchpad feature.
///
/// Standalone `*Logic` enum following the codebase convention
/// (`UniqueFileURLLogic`, `WorkflowFilenameLogic`, …). No UIKit/AppKit coupling
/// so it stays testable.
enum ScratchpadFilenameLogic {
    /// Auto-generated base name (without extension), mirroring the macOS
    /// screenshot naming style: `Note 2026-05-29 at 14.32.15`.
    static func defaultBaseName(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Note \(formatter.string(from: date))"
    }

    /// Normalizes user-entered text into a safe base name (without extension).
    /// Empty/whitespace input falls back to the provided base name.
    static func resolveBaseName(userInput: String?, fallback: String) -> String {
        let raw = (userInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return fallback }

        // Reuse the screenshot sanitizer (the existing idiom) to strip
        // ".md" / "/" / ":" / etc.
        let fakeURL = URL(fileURLWithPath: "/tmp/\(raw).md")
        let sanitized = WorkflowFilenameLogic.sanitizeFilename(raw, preservingExtensionOf: fakeURL)
        let withoutExt = (sanitized as NSString).deletingPathExtension
        return withoutExt.isEmpty ? fallback : withoutExt
    }
}
