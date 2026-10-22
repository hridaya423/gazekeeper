import Foundation

public struct BreakOverlayModel: Equatable, Sendable {

  public let isPresented: Bool
  public let remainingSeconds: Int
  public let totalSeconds: Int
  public let message: String
  public let allowEsc: Bool
  public let reduceMotion: Bool
  public let isLong: Bool
  /// Snoozes left on this break. Nil when the snooze limit is off —
  /// the overlay shows no counter then.
  public let snoozesRemaining: Int?

  public init(
    isPresented: Bool,
    remainingSeconds: Int,
    totalSeconds: Int,
    message: String,
    allowEsc: Bool,
    reduceMotion: Bool,
    isLong: Bool = false,
    snoozesRemaining: Int? = nil
  ) {
    self.isPresented = isPresented
    self.remainingSeconds = remainingSeconds
    self.totalSeconds = totalSeconds
    self.message = message
    self.allowEsc = allowEsc
    self.reduceMotion = reduceMotion
    self.isLong = isLong
    self.snoozesRemaining = snoozesRemaining
  }

  /// Skip stays hidden for the first three seconds — a break you're
  /// about to leave anyway doesn't need an exit sign the whole time.
  /// Esc follows the same rule; both surfaces read this one property.
  public var skipRevealed: Bool {
    isPresented && totalSeconds - remainingSeconds >= 3
  }

  public var progress: Double {
    guard isPresented, totalSeconds > 0 else { return 0 }
    return Self.clampedProgress(remaining: Double(remainingSeconds), total: totalSeconds)
  }

  public static func make(
    state: SchedulerState,
    settings: GKSettingsV1,
    reduceMotion: Bool,
    now: Date
  ) -> BreakOverlayModel {
    guard state.phase == .breaking, let breakEndsAt = state.breakEndsAt else {
      return BreakOverlayModel(
        isPresented: false,
        remainingSeconds: 0,
        totalSeconds: state.currentBreakIsLong
          ? settings.longBreakSeconds : settings.breakSeconds,
        message: Self.message(from: settings, state: state),
        allowEsc: settings.allowEsc,
        reduceMotion: reduceMotion,
        isLong: state.currentBreakIsLong,
        snoozesRemaining: Self.snoozesRemaining(state: state, settings: settings)
      )
    }
    let remaining: TimeInterval
    if state.isPaused() {
      remaining = state.pausedRemaining ?? 0
    } else {
      remaining = breakEndsAt.timeIntervalSince(now)
    }
    let fallback =
      state.currentBreakIsLong
      ? settings.longBreakSeconds : settings.breakSeconds
    return BreakOverlayModel(
      isPresented: true,
      remainingSeconds: max(0, Int(remaining.rounded(.up))),
      totalSeconds: state.currentBreakSeconds > 0 ? state.currentBreakSeconds : fallback,
      message: Self.message(from: settings, state: state),
      allowEsc: settings.allowEsc,
      reduceMotion: reduceMotion,
      isLong: state.currentBreakIsLong,
      snoozesRemaining: Self.snoozesRemaining(state: state, settings: settings)
    )
  }

  private static func snoozesRemaining(state: SchedulerState, settings: GKSettingsV1) -> Int? {
    guard settings.snoozeLimit > 0 else { return nil }
    return max(0, settings.snoozeLimit - state.snoozesUsed)
  }

  public static func clampedProgress(remaining: Double, total: Int) -> Double {
    guard total > 0 else { return 0 }
    return min(1, max(0, remaining / Double(total)))
  }

  private static func message(from settings: GKSettingsV1, state: SchedulerState) -> String {
    let pool =
      state.currentBreakIsLong
      ? (settings.longMessages.isEmpty ? GKSettingsV1.defaultLongMessages : settings.longMessages)
      : (settings.messages.isEmpty ? GKSettingsV1.defaultMessages : settings.messages)
    let index = max(0, state.breaksStarted - 1) % pool.count
    return pool[index]
  }
}
