import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// Login items only make sense for a real .app bundle (not `swift run`).
    static var isSupported: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Running from /Applications or ~/Applications.
    static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        guard isSupported else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
