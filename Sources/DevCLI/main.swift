import Foundation

// Dev CLI - Build with: swift run DevCLI
// This is a command-line version for testing logic without Xcode

print("=== Screenshot App Dev CLI ===")
print("")

// Test 1: Settings
testSettings()

// Test 2: Filename Template
testFilenameTemplate()

// Test 3: Counter
testCounter()

print("")
print("=== All tests passed! ===")

func testSettings() {
    print("Test 1: Settings")
    
    // Create test settings
    var settings = TestSettings(
        quality: 90,
        maxWidth: 1200,
        notePrefixEnabled: true,
        notePrefix: "Screenshot",
        screenshotCounter: 1
    )
    
    // Test normalization
    settings.quality = 105
    settings = settings.normalized()
    assert(settings.quality == 100, "Quality should be clamped to 100")
    
    settings.quality = 5
    settings = settings.normalized()
    assert(settings.quality == 10, "Quality should be clamped to 10")
    
    settings.quality = 92
    settings = settings.normalized()
    assert(settings.quality == 90, "Quality should quantize to step 5")
    
    settings.notePrefix = String(repeating: "A", count: 60)
    settings = settings.normalized()
    assert(settings.notePrefix.count == 50, "Note prefix should be truncated to 50")
    
    print("  ✓ Settings normalization works")
}

func testFilenameTemplate() {
    print("Test 2: Filename Template")
    
    var template = FilenameTemplate(blocks: [
        TemplateBlock(kind: .staticText, text: "Screenshot"),
        TemplateBlock(kind: .date, format: "yyyy-MM-dd"),
        TemplateBlock(kind: .time, format: "HH.mm.ss"),
        TemplateBlock(kind: .counter)
    ])
    
    let filename = template.makeFilename(date: Date(), counter: 42)
    assert(filename.contains("Screenshot"), "Should contain static text")
    assert(filename.contains("42"), "Should contain counter")
    
    // Test constraint: at least time or counter must be enabled
    template.blocks[2].isEnabled = false
    template.blocks[3].isEnabled = false
    template.ensureTimeOrCounterEnabled()
    assert(template.blocks[3].isEnabled, "Counter should be auto-enabled")
    
    print("  ✓ Filename template works")
}

func testCounter() {
    print("Test 3: Counter")
    
    var counter = 1
    
    // Simulate taking 5 screenshots
    for i in 1...5 {
        let currentCounter = counter
        counter = currentCounter + 1
        assert(currentCounter == i, "Counter should be \(i)")
    }
    
    assert(counter == 6, "Final counter should be 6")
    print("  ✓ Counter increments correctly")
}

// MARK: - Test Models (Foundation-only versions)

struct TestSettings {
    var quality: Int
    var maxWidth: Int
    var notePrefixEnabled: Bool
    var notePrefix: String
    var screenshotCounter: Int
    
    func normalized() -> TestSettings {
        var copy = self
        
        // Clamp quality 10-100, step 5
        let clampedQuality = min(100, max(10, quality))
        copy.quality = (clampedQuality / 5) * 5
        
        // Ensure maxWidth >= 0
        copy.maxWidth = max(0, maxWidth)
        
        // Truncate note prefix to 50
        if copy.notePrefix.count > 50 {
            copy.notePrefix = String(copy.notePrefix.prefix(50))
        }
        
        // Ensure counter >= 1
        copy.screenshotCounter = max(1, screenshotCounter)
        
        return copy
    }
}

struct FilenameTemplate {
    var blocks: [TemplateBlock]
    
    func makeFilename(date: Date, counter: Int) -> String {
        var components: [String] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        for block in blocks where block.isEnabled {
            switch block.kind {
            case .staticText:
                if let text = block.text, !text.isEmpty {
                    components.append(text)
                }
            case .date:
                formatter.dateFormat = block.format ?? "yyyy-MM-dd"
                components.append(formatter.string(from: date))
            case .time:
                formatter.dateFormat = block.format ?? "HH.mm.ss"
                components.append(formatter.string(from: date))
            case .counter:
                if counter > 1 {
                    components.append(String(counter))
                }
            }
        }
        
        return components.joined(separator: "_")
    }
    
    mutating func ensureTimeOrCounterEnabled() {
        let hasEnabled = blocks.contains { block in
            guard block.isEnabled else { return false }
            return block.kind == .time || block.kind == .counter
        }
        
        if !hasEnabled {
            // Enable counter
            if let index = blocks.firstIndex(where: { $0.kind == .counter }) {
                blocks[index].isEnabled = true
            }
        }
    }
}

struct TemplateBlock {
    enum Kind {
        case date, time, counter, staticText
    }
    
    var kind: Kind
    var isEnabled: Bool = true
    var text: String?
    var format: String?
}
