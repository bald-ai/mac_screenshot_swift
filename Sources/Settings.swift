import Foundation
import Carbon

/// Top-level settings model persisted to ~/.screenshot_app_settings.json
struct Settings: Codable {
    /// JPEG quality 10–100, step 5.
    var quality: Int

    /// Maximum width in pixels (0 = original size).
    var maxWidth: Int

    /// Whether to prepend a fixed prefix to burned-in notes.
    var notePrefixEnabled: Bool

    /// Optional prefix text for burned-in notes (max 50 chars).
    var notePrefix: String

    /// Filename templating configuration.
    var filenameTemplate: FilenameTemplate

    /// Global shortcut configuration.
    var shortcuts: Shortcuts
}

extension Settings {
    /// Default settings used on first launch or when decoding fails.
    static let `default` = Settings(
        quality: 90,
        maxWidth: 0,
        notePrefixEnabled: false,
        notePrefix: "",
        filenameTemplate: .defaultTemplate,
        shortcuts: .default
    )

    /// Returns a copy normalized to all invariants/constraints.
    func normalized() -> Settings {
        var copy = self

        // Clamp and quantize quality to 10–100, step 5.
        let clampedQuality = min(100, max(10, quality))
        copy.quality = (clampedQuality / 5) * 5

        // Ensure maxWidth is never negative; 0 means "Original".
        copy.maxWidth = max(0, maxWidth)

        // Ensure note prefix length <= 50.
        if copy.notePrefix.count > 50 {
            copy.notePrefix = String(copy.notePrefix.prefix(50))
        }

        // Enforce filename template invariants.
        copy.filenameTemplate.ensureTimeOrCounterEnabled()

        return copy
    }
}

// MARK: - Shortcuts

/// A single global shortcut (Carbon keyCode + modifiers).
struct Shortcut: Codable, Equatable, Hashable {
    /// Carbon virtual key code (kVK_* constants).
    var keyCode: UInt32

    /// Carbon modifier flags (cmd/alt/ctrl/shift).
    var modifierFlags: UInt32

    init(keyCode: UInt32, modifierFlags: UInt32) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
}

/// Grouping of all shortcuts used by the app.
struct Shortcuts: Codable, Equatable {
    var screenshotArea: Shortcut
    var screenshotFull: Shortcut
    var stitchImages: Shortcut
}

extension Shortcuts {
    /// Reasonable, non-conflicting defaults.
    /// These can later be changed via the shortcut recorder UI.
    static let `default` = Shortcuts(
        // Cmd + Shift + 6
        screenshotArea: Shortcut(
            keyCode: UInt32(kVK_ANSI_6),
            modifierFlags: UInt32(cmdKey | shiftKey)
        ),
        // Cmd + Shift + 7
        screenshotFull: Shortcut(
            keyCode: UInt32(kVK_ANSI_7),
            modifierFlags: UInt32(cmdKey | shiftKey)
        ),
        // Cmd + Shift + 8
        stitchImages: Shortcut(
            keyCode: UInt32(kVK_ANSI_8),
            modifierFlags: UInt32(cmdKey | shiftKey)
        )
    )
}

// MARK: - Filename Template

/// Template that controls how screenshot filenames are generated.
struct FilenameTemplate: Codable {
    struct Block: Codable, Identifiable, Equatable {
        enum Kind: String, Codable {
            case date
            case time
            case counter
            case staticText
        }

        var id: UUID
        var kind: Kind
        var isEnabled: Bool

        /// Optional text used for `.staticText` blocks.
        var text: String?

        /// Optional format string for date/time blocks.
        /// Examples: "yyyy-MM-dd", "HH.mm.ss".
        var format: String?

        init(id: UUID = UUID(), kind: Kind, isEnabled: Bool = true, text: String? = nil, format: String? = nil) {
            self.id = id
            self.kind = kind
            self.isEnabled = isEnabled
            self.text = text
            self.format = format
        }
    }

    /// Ordered list of blocks making up the filename (without extension).
    var blocks: [Block]
}

extension FilenameTemplate {
    /// Default filename template roughly matching common screenshot conventions.
    /// Example outcome: "Screenshot_2024-01-30_14.23.45_2.jpg".
    static let defaultTemplate: FilenameTemplate = {
        let screenshot = Block(kind: .staticText, isEnabled: true, text: "Screenshot")
        let date = Block(kind: .date, isEnabled: true, text: nil, format: "yyyy-MM-dd")
        let time = Block(kind: .time, isEnabled: true, text: nil, format: "HH.mm.ss")
        let counter = Block(kind: .counter, isEnabled: true)
        return FilenameTemplate(blocks: [screenshot, date, time, counter])
    }()

    /// Ensures that at least one of `.time` or `.counter` is enabled.
    /// This is critical to avoid filename collisions.
    mutating func ensureTimeOrCounterEnabled() {
        let hasTimeOrCounterEnabled = blocks.contains { block in
            guard block.isEnabled else { return false }
            return block.kind == .time || block.kind == .counter
        }

        if hasTimeOrCounterEnabled {
            return
        }

        // Prefer enabling an existing counter block if present.
        if let counterIndex = blocks.firstIndex(where: { $0.kind == .counter }) {
            blocks[counterIndex].isEnabled = true
            return
        }

        // Otherwise enable an existing time block.
        if let timeIndex = blocks.firstIndex(where: { $0.kind == .time }) {
            blocks[timeIndex].isEnabled = true
            return
        }

        // As a last resort, append a counter block.
        let counter = Block(kind: .counter, isEnabled: true)
        blocks.append(counter)
    }

    /// Reorders a block by id. No-op if the id or index is invalid.
    mutating func moveBlock(id: UUID, to newIndex: Int) {
        guard let currentIndex = blocks.firstIndex(where: { $0.id == id }) else { return }
        let boundedIndex = max(0, min(newIndex, blocks.count - 1))
        guard currentIndex != boundedIndex else { return }

        let block = blocks.remove(at: currentIndex)
        blocks.insert(block, at: boundedIndex)
    }

    /// Toggles a block's enabled state, but preserves the time/counter invariant.
    mutating func setBlockEnabled(id: UUID, isEnabled: Bool) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].isEnabled = isEnabled
        ensureTimeOrCounterEnabled()
    }

    /// Generates a concrete filename (without extension) for the given date + counter.
    /// The counter here is the logical counter value (e.g. 1, 2, 3) – collision
    /// handling ("_2", "_3", ...) is owned by `ScreenshotService`.
    func makeFilenameComponents(date: Date, counter: Int) -> [String] {
        var components: [String] = []

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        for block in blocks where block.isEnabled {
            switch block.kind {
            case .staticText:
                if let text = block.text, !text.isEmpty {
                    components.append(text)
                }
            case .date:
                dateFormatter.dateFormat = block.format ?? "yyyy-MM-dd"
                components.append(dateFormatter.string(from: date))
            case .time:
                dateFormatter.dateFormat = block.format ?? "HH.mm.ss"
                components.append(dateFormatter.string(from: date))
            case .counter:
                // Only append counter when > 1 so first screenshot is cleaner.
                if counter > 1 {
                    components.append(String(counter))
                }
            }
        }

        return components
    }

    /// Convenience for building the final filename string (without extension).
    func makeFilename(date: Date = Date(), counter: Int = 1) -> String {
        let components = makeFilenameComponents(date: date, counter: counter)
        guard !components.isEmpty else { return "Screenshot" }
        return components.joined(separator: "_")
    }
}
