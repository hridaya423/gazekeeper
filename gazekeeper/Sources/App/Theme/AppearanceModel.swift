import GazeKeeperCore
import SwiftUI

/// Reduce-motion + onboarding facade over the controller's settings.
/// Appearance state is settings state — this model reads it live and
/// writes through the same sanitized path everything else uses.
@MainActor
@Observable
final class AppearanceModel {
  private let controller: AppStateController

  init(controller: AppStateController) {
    self.controller = controller
  }

  var hasCompletedOnboarding: Bool {
    controller.currentSettings.hasCompletedOnboarding
  }

  var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// The accent everywhere: the brand teal, or the user's system accent
  /// when they ask for it. Resolved live — flipping the setting repaints
  /// every surface through the @Observable dependency.
  var accent: Color {
    controller.currentSettings.accentChoice == .system
      ? Color(nsColor: .controlAccentColor)
      : Tokens.Color.accent
  }

  /// Text on an accent fill — white over the system accent is the
  /// platform contract; the brand teal keeps its tuned pair.
  var onAccent: Color {
    controller.currentSettings.accentChoice == .system
      ? .white
      : Tokens.Color.onAccent
  }

  func completeOnboarding() {
    controller.completeOnboarding()
  }
}
