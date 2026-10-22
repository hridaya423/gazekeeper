import GazeKeeperCore
import UserNotifications

/// System notifications, used only where an on-screen panel can't be:
/// the heads-up when the pill is suppressed (a fullscreen app owns the
/// display and the fullscreen detector is off). Everything else the app
/// says on screen — pill, overlay, wellness toasts — stays on screen.
@MainActor
final class NotificationBridge {

  private static let headsUpIdentifier = "gazekeeper.heads-up"

  /// Asked once, when onboarding finishes — the only place a system
  /// permission prompt fits the flow. Denial is quiet: the pill is the
  /// primary surface and keeps working without it.
  func requestAuthorizationIfNeeded() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      guard settings.authorizationStatus == .notDetermined else { return }
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
  }

  /// Fires the heads-up through Notification Center. Called once per due
  /// by the controller — the request replaces itself, so a stale banner
  /// can never outlive the heads-up it announced.
  func sendHeadsUp(dueIn seconds: TimeInterval) {
    let content = UNMutableNotificationContent()
    content.title = "Break starting soon"
    content.body =
      seconds > 1
      ? "Look away in \(Int(seconds.rounded(.up))) seconds — or take the break now."
      : "Time to look away."
    content.interruptionLevel = .timeSensitive
    let request = UNNotificationRequest(
      identifier: Self.headsUpIdentifier,
      content: content,
      trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  /// The heads-up ended without a break (skipped, postponed, detector
  /// pause) — clear the banner so it never announces a stale break.
  func retractHeadsUp() {
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: [Self.headsUpIdentifier])
    center.removePendingNotificationRequests(withIdentifiers: [Self.headsUpIdentifier])
  }
}
