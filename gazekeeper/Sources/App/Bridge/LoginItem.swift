import Foundation
import ServiceManagement

/// Backs the "Launch at login" setting with the real SMAppService registration.
enum LoginItem {

  static func setEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      NSLog(
        "GazeKeeper launch-at-login \(enabled ? "register" : "unregister") failed: \(error)")
    }
  }

  /// Whether the app will actually launch at login. `.requiresApproval` counts
  /// as off: the user still has to confirm it in System Settings.
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Reconciles the stored preference with the system truth. Returns the value
  /// the stored setting should hold. System Settings is the source of truth
  /// when it disagrees: a user who turned us off there stays off.
  static func reconciledValue(stored: Bool) -> Bool {
    let status = SMAppService.mainApp.status
    if stored && status == .requiresApproval {
      NSLog("GazeKeeper launch-at-login requires approval in System Settings")
    }
    if stored && status == .notFound {
      // Persisted intent that was never registered (e.g. failed earlier or
      // restored defaults): assert it once.
      setEnabled(true)
    }
    return isEnabled
  }
}
