import Foundation

/// Fetches the currently selected item in Finder via AppleScript.
///
/// Note: this requires the user to allow the app to control Finder
/// in System Settings > Privacy & Security > Automation.
enum FinderSelectionService {
    enum Selection: Equatable {
        case none
        case multiple(count: Int)
        case single(url: URL)
    }

    /// Returns Finder selection state (none / multiple / single file URL).
    static func selection(scriptRunner: (String) throws -> String = runAppleScriptReturningString) throws -> Selection {
        // Finder's `selection` is documented as "the selection in the frontmost Finder window".
        // Key detail: Desktop icon selection can still be returned by `get selection`, but
        // `count of selection` may misleadingly be 0. So we must NOT gate on `count`.
        //
        // We attempt to read `item 1 of (get selection)` directly. If it fails, we retry
        // once after bringing Finder frontmost.
        let scriptNoBringToFront = """
        tell application "Finder"
            try
                set s to (get selection)
                set n to (count of s)
                if n is 0 then return "NONE"
                if n is not 1 then return "MULTI:" & n
                set theItem to item 1 of s
                return "ONE:" & POSIX path of (theItem as alias)
            on error
                return "NONE"
            end try
        end tell
        """

        let scriptBringToFront = """
        tell application "Finder"
            set visible to true
            set frontmost to true
            activate
            delay 0.15
            try
                set s to (get selection)
                set n to (count of s)
                if n is 0 then return "NONE"
                if n is not 1 then return "MULTI:" & n
                set theItem to item 1 of s
                return "ONE:" & POSIX path of (theItem as alias)
            on error
                return "NONE"
            end try
        end tell
        """

        let raw1 = try scriptRunner(scriptNoBringToFront)
        let parsed1 = FinderSelectionParser.parseSelectionResult(raw1)
        switch parsed1 {
        case .none:
            break
        case .multiple, .single:
            return parsed1
        }

        let raw2 = try scriptRunner(scriptBringToFront)
        let parsed2 = FinderSelectionParser.parseSelectionResult(raw2)
        switch parsed2 {
        case .none:
            return .none
        case .multiple, .single:
            return parsed2
        }
    }

    private static func runAppleScriptReturningString(_ source: String) throws -> String {
        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else {
            throw NSError(domain: "FinderSelectionService",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create AppleScript."])
        }

        let result = appleScript.executeAndReturnError(&errorDict)

        if let errorDict = errorDict {
            let message = (errorDict[NSAppleScript.errorMessage] as? String)
                ?? (errorDict["NSAppleScriptErrorMessage"] as? String)
                ?? "Unknown AppleScript error."
            throw NSError(domain: "FinderSelectionService",
                          code: -2,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }

        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

}

enum FinderSelectionParser {
    static func parseSelectionResult(_ raw: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> FinderSelectionService.Selection {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "NONE" {
            return .none
        }

        if value.hasPrefix("MULTI:") {
            let num = value.dropFirst("MULTI:".count)
            let count = Int(num) ?? 2
            return .multiple(count: max(2, count))
        }

        if value.hasPrefix("ONE:") {
            let path = String(value.dropFirst("ONE:".count))
            if let url = urlFromPath(path, fileExists: fileExists) {
                return .single(url: url)
            }
            return .none
        }

        // Unexpected output; treat as none.
        return .none
    }

    private static func urlFromPath(_ path: String, fileExists: (String) -> Bool) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard fileExists(trimmed) else { return nil }
        return URL(fileURLWithPath: trimmed)
    }
}
