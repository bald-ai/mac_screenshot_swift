import CoreGraphics

enum ScreenRecordingPermissionLogic {
    static func ensurePermission(preflight: () -> Bool,
                                 request: () -> Bool) -> Bool {
        if preflight() {
            return true
        }

        return request()
    }
}
