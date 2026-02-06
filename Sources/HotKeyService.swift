import Foundation
import AppKit
import Carbon

/// Manages global shortcuts using the Carbon `RegisterEventHotKey` API.
///
/// This service owns the lifecycle of the global hotkeys and provides a small
/// surface area for the rest of the app:
/// - `registerShortcuts(settings:areaHandler:fullHandler:stitchHandler:)` is
///    called once on launch from `AppDelegate`.
/// - `updateShortcuts(settings:)` is called whenever the user changes shortcut
///    preferences in the settings window.
final class HotKeyService {
    typealias Handler = () -> Void

    private enum HotKeyKind: UInt32 {
        case screenshotArea = 1
        case screenshotFull = 2
        case stitchImages  = 3
    }

    private struct Registration {
        let ref: EventHotKeyRef
        let handler: Handler
    }

    private static let hotKeySignature: OSType = HotKeyService.fourCharCode("SSAP")

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var isEventHandlerInstalled = false

    private var areaHandler: Handler?
    private var fullHandler: Handler?
    private var stitchHandler: Handler?

    init() {
        installEventHandlerIfNeeded()
    }

    deinit {
        unregisterAll()
    }

    /// Registers the three primary shortcuts and installs their handlers.
    ///
    /// This should be called once during app launch. Subsequent changes to the
    /// shortcuts (via the settings UI) should go through `updateShortcuts`.
    func registerShortcuts(
        settings: Settings,
        areaHandler: @escaping Handler,
        fullHandler: @escaping Handler,
        stitchHandler: @escaping Handler
    ) {
        Logger.shared.info("HotKeyService: registerShortcuts called")
        self.areaHandler = areaHandler
        self.fullHandler = fullHandler
        self.stitchHandler = stitchHandler

        applyShortcuts(from: settings)
        Logger.shared.info("HotKeyService: registerShortcuts completed")
    }

    /// Re-applies the current handlers using updated shortcut definitions.
    ///
    /// This is used by the settings window when the user records new
    /// key combinations.
    func updateShortcuts(settings: Settings) {
        guard areaHandler != nil, fullHandler != nil, stitchHandler != nil else {
            return
        }
        applyShortcuts(from: settings)
    }

    // MARK: - Internal registration

    private func applyShortcuts(from settings: Settings) {
        Logger.shared.info("HotKeyService: applyShortcuts called")
        unregisterAll()
        installEventHandlerIfNeeded()

        registerShortcut(kind: .screenshotArea,
                         shortcut: settings.shortcuts.screenshotArea,
                         handler: areaHandler)
        registerShortcut(kind: .screenshotFull,
                         shortcut: settings.shortcuts.screenshotFull,
                         handler: fullHandler)
        registerShortcut(kind: .stitchImages,
                         shortcut: settings.shortcuts.stitchImages,
                         handler: stitchHandler)
        Logger.shared.info("HotKeyService: applyShortcuts completed")
    }

    private func registerShortcut(kind: HotKeyKind, shortcut: Shortcut, handler: Handler?) {
        guard let handler = handler else { return }

        var hotKeyRef: EventHotKeyRef?
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = HotKeyService.hotKeySignature
        hotKeyID.id = kind.rawValue

        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            registrations[hotKeyID.id] = Registration(ref: ref, handler: handler)
        } else {
            NSLog("[HotKeyService] Failed to register hotkey (kind: \(kind), status: \(status))")
        }
    }

    private func unregisterAll() {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    private func installEventHandlerIfNeeded() {
        guard !isEventHandlerInstalled else { return }

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = UInt32(kEventHotKeyPressed)

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )

        if status == noErr {
            isEventHandlerInstalled = true
        } else {
            NSLog("[HotKeyService] Failed to install hotkey event handler: \(status)")
        }
    }

    fileprivate func handleHotKey(with id: EventHotKeyID) {
        Logger.shared.info("HotKeyService: handleHotKey called with id \(id.id)")
        guard id.signature == HotKeyService.hotKeySignature else {
            Logger.shared.error("HotKeyService: Invalid signature")
            return
        }
        guard let registration = registrations[id.id] else {
            Logger.shared.error("HotKeyService: No registration found for id \(id.id)")
            return
        }
        Logger.shared.info("HotKeyService: Executing handler for id \(id.id)")
        registration.handler()
        Logger.shared.info("HotKeyService: Handler completed for id \(id.id)")
    }

    // MARK: - Helpers

    private static func fourCharCode(_ string: String) -> OSType {
        var result: UInt32 = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return OSType(result)
    }

    /// Converts Cocoa modifier flags to Carbon flags suitable for
    /// `RegisterEventHotKey`.
    static func carbonModifierFlags(from cocoaFlags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = cocoaFlags.intersection([.command, .option, .control, .shift, .capsLock])
        var newFlags: Int = 0

        if flags.contains(.control) { newFlags |= controlKey }
        if flags.contains(.command) { newFlags |= cmdKey }
        if flags.contains(.shift) { newFlags |= shiftKey }
        if flags.contains(.option) { newFlags |= optionKey }
        if flags.contains(.capsLock) { newFlags |= alphaLock }

        return UInt32(newFlags)
    }

    private static func modifierDescription(for carbonFlags: UInt32) -> String {
        var result = ""
        if (carbonFlags & UInt32(controlKey)) != 0 { result.append("⌃") }
        if (carbonFlags & UInt32(optionKey)) != 0 { result.append("⌥") }
        if (carbonFlags & UInt32(shiftKey)) != 0 { result.append("⇧") }
        if (carbonFlags & UInt32(cmdKey)) != 0 { result.append("⌘") }
        return result
    }

    /// Returns a human-readable description of the shortcut, e.g. "⌘⇧6".
    static func describeShortcut(keyCode: UInt32, carbonFlags: UInt32) -> String {
        let keyString = keyName(for: UInt16(keyCode)) ?? "?"
        let modifiers = modifierDescription(for: carbonFlags)
        return modifiers + keyString
    }

    /// Returns true if the given key code is allowed for user-recorded
    /// shortcuts.
    static func isAllowedKeyCode(_ keyCode: UInt16) -> Bool {
        return keyCodeToString[keyCode] != nil
    }

    private static func keyName(for keyCode: UInt16) -> String? {
        return keyCodeToString[keyCode]
    }

    private static let keyCodeToString: [UInt16: String] = {
        var map: [UInt16: String] = [:]

        // Letters A–Z
        map[UInt16(kVK_ANSI_A)] = "A"
        map[UInt16(kVK_ANSI_B)] = "B"
        map[UInt16(kVK_ANSI_C)] = "C"
        map[UInt16(kVK_ANSI_D)] = "D"
        map[UInt16(kVK_ANSI_E)] = "E"
        map[UInt16(kVK_ANSI_F)] = "F"
        map[UInt16(kVK_ANSI_G)] = "G"
        map[UInt16(kVK_ANSI_H)] = "H"
        map[UInt16(kVK_ANSI_I)] = "I"
        map[UInt16(kVK_ANSI_J)] = "J"
        map[UInt16(kVK_ANSI_K)] = "K"
        map[UInt16(kVK_ANSI_L)] = "L"
        map[UInt16(kVK_ANSI_M)] = "M"
        map[UInt16(kVK_ANSI_N)] = "N"
        map[UInt16(kVK_ANSI_O)] = "O"
        map[UInt16(kVK_ANSI_P)] = "P"
        map[UInt16(kVK_ANSI_Q)] = "Q"
        map[UInt16(kVK_ANSI_R)] = "R"
        map[UInt16(kVK_ANSI_S)] = "S"
        map[UInt16(kVK_ANSI_T)] = "T"
        map[UInt16(kVK_ANSI_U)] = "U"
        map[UInt16(kVK_ANSI_V)] = "V"
        map[UInt16(kVK_ANSI_W)] = "W"
        map[UInt16(kVK_ANSI_X)] = "X"
        map[UInt16(kVK_ANSI_Y)] = "Y"
        map[UInt16(kVK_ANSI_Z)] = "Z"

        // Numbers 0–9 (top row)
        map[UInt16(kVK_ANSI_0)] = "0"
        map[UInt16(kVK_ANSI_1)] = "1"
        map[UInt16(kVK_ANSI_2)] = "2"
        map[UInt16(kVK_ANSI_3)] = "3"
        map[UInt16(kVK_ANSI_4)] = "4"
        map[UInt16(kVK_ANSI_5)] = "5"
        map[UInt16(kVK_ANSI_6)] = "6"
        map[UInt16(kVK_ANSI_7)] = "7"
        map[UInt16(kVK_ANSI_8)] = "8"
        map[UInt16(kVK_ANSI_9)] = "9"

        // Function keys F1–F12
        map[UInt16(kVK_F1)] = "F1"
        map[UInt16(kVK_F2)] = "F2"
        map[UInt16(kVK_F3)] = "F3"
        map[UInt16(kVK_F4)] = "F4"
        map[UInt16(kVK_F5)] = "F5"
        map[UInt16(kVK_F6)] = "F6"
        map[UInt16(kVK_F7)] = "F7"
        map[UInt16(kVK_F8)] = "F8"
        map[UInt16(kVK_F9)] = "F9"
        map[UInt16(kVK_F10)] = "F10"
        map[UInt16(kVK_F11)] = "F11"
        map[UInt16(kVK_F12)] = "F12"

        // Whitespace and control keys
        map[UInt16(kVK_Space)] = "Space"
        map[UInt16(kVK_Return)] = "Return"
        map[UInt16(kVK_Tab)] = "Tab"
        map[UInt16(kVK_Escape)] = "Esc"
        map[UInt16(kVK_Delete)] = "⌫"

        // Common punctuation
        map[UInt16(kVK_ANSI_Grave)] = "`"
        map[UInt16(kVK_ANSI_Minus)] = "-"
        map[UInt16(kVK_ANSI_Equal)] = "="
        map[UInt16(kVK_ANSI_LeftBracket)] = "["
        map[UInt16(kVK_ANSI_RightBracket)] = "]"
        map[UInt16(kVK_ANSI_Backslash)] = "\\"
        map[UInt16(kVK_ANSI_Semicolon)] = ";"
        map[UInt16(kVK_ANSI_Quote)] = "'"
        map[UInt16(kVK_ANSI_Comma)] = ","
        map[UInt16(kVK_ANSI_Period)] = "."
        map[UInt16(kVK_ANSI_Slash)] = "/"

        return map
    }()
}

// MARK: - Carbon callback

private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event, let userData = userData else {
        return noErr
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr else {
        return status
    }

    let service = Unmanaged<HotKeyService>
        .fromOpaque(userData)
        .takeUnretainedValue()

    service.handleHotKey(with: hotKeyID)

    return noErr
}
