import GazeKeeperCore
import SwiftUI

extension EnvironmentValues {
  /// The resolved accent. Defaults to the brand teal so pre-boot views
  /// and snapshot fixtures never need the setting injected.
  @Entry var gkAccent: Color = Tokens.Color.accent
  /// Text drawn on an accent fill — the system accent pairs with white.
  @Entry var gkOnAccent: Color = Tokens.Color.onAccent
}

extension View {
  /// Pushes the settings-resolved accent down the tree. Called inside a
  /// `body`, so a settings change re-renders the parent and re-pushes
  /// the value — nothing reads it out-of-band or goes stale.
  func gkAccent(from settings: GKSettingsV1) -> some View {
    let system = settings.accentChoice == .system
    return
      self
      .environment(
        \.gkAccent,
        system ? Color(nsColor: .controlAccentColor) : Tokens.Color.accent
      )
      .environment(\.gkOnAccent, system ? .white : Tokens.Color.onAccent)
  }
}
