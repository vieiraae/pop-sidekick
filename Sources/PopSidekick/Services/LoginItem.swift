import Foundation
import ServiceManagement

/// Registers or unregisters the app as a macOS login item so "Launch at login"
/// actually takes effect (the setting was previously persisted but never applied).
enum LoginItem {
    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Applies the desired launch-at-login state, registering or unregistering
    /// the main app service. Failures are logged but non-fatal.
    static func apply(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Diag.log("LoginItem: failed to set enabled=\(enabled): \(error)")
        }
    }

    /// Reconciles the registered state with the saved setting at launch.
    static func sync(with enabled: Bool) {
        if enabled != isEnabled {
            apply(enabled: enabled)
        }
    }
}
