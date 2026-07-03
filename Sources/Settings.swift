import Foundation
import Carbon

/// Top-level settings model persisted to ~/.screenshot_app_settings.json
struct Settings: Codable {
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

    /// Global screenshot counter for filename generation.
    var screenshotCounter: Int
}

extension Settings {
    /// Default settings used on first launch or when decoding fails.
    static let `default` = Settings(
        maxWidth: 0,
        notePrefixEnabled: false,
        notePrefix: "",
        filenameTemplate: .defaultTemplate,
        shortcuts: .default,
        screenshotCounter: 1
    )

    /// Returns a copy normalized to all invariants/constraints.
    func normalized() -> Settings {
        var copy = self

        // Ensure maxWidth is never negative; 0 means "Original".
        copy.maxWidth = max(0, maxWidth)

        // Ensure note prefix length <= 50.
        if copy.notePrefix.count > 50 {
            copy.notePrefix = String(copy.notePrefix.prefix(50))
        }

        // Ensure screenshot counter is always >= 1.
        copy.screenshotCounter = max(1, screenshotCounter)

        // Move older shipped defaults to the current product-intended defaults.
        copy.shortcuts.replaceRetiredDefaultShortcutsIfNeeded()

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
    var reopenFinderSelection: Shortcut
    var openScratchpad: Shortcut
}

extension Shortcuts {
    /// Reasonable, non-conflicting defaults.
    /// These can later be changed via the shortcut recorder UI.
    static let `default` = Shortcuts(
        // Option + Shift + 4
        screenshotArea: Shortcut(
            keyCode: UInt32(kVK_ANSI_4),
            modifierFlags: UInt32(optionKey | shiftKey)
        ),
        // Option + Shift + 3
        screenshotFull: Shortcut(
            keyCode: UInt32(kVK_ANSI_3),
            modifierFlags: UInt32(optionKey | shiftKey)
        ),
        // Option + Shift + 2
        reopenFinderSelection: Shortcut(
            keyCode: UInt32(kVK_ANSI_2),
            modifierFlags: UInt32(optionKey | shiftKey)
        ),
        // Option + Shift + 5
        openScratchpad: Shortcut(
            keyCode: UInt32(kVK_ANSI_5),
            modifierFlags: UInt32(optionKey | shiftKey)
        )
    )
}

extension Shortcuts {
    mutating func replaceRetiredDefaultShortcutsIfNeeded() {
        let retiredArea = Shortcut(
            keyCode: UInt32(kVK_ANSI_4),
            modifierFlags: UInt32(controlKey | shiftKey)
        )
        let retiredFull = Shortcut(
            keyCode: UInt32(kVK_ANSI_3),
            modifierFlags: UInt32(controlKey | shiftKey)
        )
        let retiredReopenFinderSelection = Shortcut(
            keyCode: UInt32(kVK_ANSI_2),
            modifierFlags: UInt32(controlKey | shiftKey)
        )
        let retiredOpenScratchpad = Shortcut(
            keyCode: UInt32(kVK_ANSI_5),
            modifierFlags: UInt32(cmdKey | shiftKey)
        )
        let temporaryOpenScratchpad = Shortcut(
            keyCode: UInt32(kVK_ANSI_N),
            modifierFlags: UInt32(controlKey | shiftKey)
        )

        if screenshotArea == retiredArea {
            screenshotArea = Shortcuts.default.screenshotArea
        }
        if screenshotFull == retiredFull {
            screenshotFull = Shortcuts.default.screenshotFull
        }
        if reopenFinderSelection == retiredReopenFinderSelection {
            reopenFinderSelection = Shortcuts.default.reopenFinderSelection
        }
        if openScratchpad == retiredOpenScratchpad {
            openScratchpad = Shortcuts.default.openScratchpad
        }
        if openScratchpad == temporaryOpenScratchpad {
            openScratchpad = Shortcuts.default.openScratchpad
        }
    }
}

extension Shortcuts {
    // Backward-compatible decoding: older settings files won't have the new key.
    private enum CodingKeys: String, CodingKey {
        case screenshotArea
        case screenshotFull
        case reopenFinderSelection
        case openScratchpad
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.screenshotArea = try container.decodeIfPresent(Shortcut.self, forKey: .screenshotArea)
            ?? Shortcuts.default.screenshotArea
        self.screenshotFull = try container.decodeIfPresent(Shortcut.self, forKey: .screenshotFull)
            ?? Shortcuts.default.screenshotFull
        self.reopenFinderSelection = try container.decodeIfPresent(Shortcut.self, forKey: .reopenFinderSelection)
            ?? Shortcuts.default.reopenFinderSelection
        self.openScratchpad = try container.decodeIfPresent(Shortcut.self, forKey: .openScratchpad)
            ?? Shortcuts.default.openScratchpad
    }
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
    /// Example outcome: "Screenshot_2024-01-30_14.23.45_2.png".
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

        for block in blocks where block.isEnabled {
            switch block.kind {
            case .staticText:
                if let text = block.text, !text.isEmpty {
                    components.append(text)
                }
            case .date:
                let format = (block.format?.isEmpty == false ? block.format : nil) ?? "yyyy-MM-dd"
                components.append(FilenameDateFormatterCache.string(from: date, format: format))
            case .time:
                let format = (block.format?.isEmpty == false ? block.format : nil) ?? "HH.mm.ss"
                components.append(FilenameDateFormatterCache.string(from: date, format: format))
            case .counter:
                // Always include counter when the block is enabled.
                components.append(String(counter))
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

private enum FilenameDateFormatterCache {
    private static let cache = ThreadSafeDateFormatterCache()

    static func string(from date: Date, format: String) -> String {
        cache.string(from: date, format: format)
    }
}

private final class ThreadSafeDateFormatterCache {
    private var formatters: [String: DateFormatter] = [:]
    private let lock = NSLock()
    private let locale = Locale(identifier: "en_US_POSIX")

    func string(from date: Date, format: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        let formatter: DateFormatter
        if let existing = formatters[format] {
            formatter = existing
        } else {
            let created = DateFormatter()
            created.locale = locale
            created.dateFormat = format
            formatters[format] = created
            formatter = created
        }
        return formatter.string(from: date)
    }
}
