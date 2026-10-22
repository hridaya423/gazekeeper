import Foundation

public enum WellnessNudgeKind: String, Equatable, Codable, CaseIterable, Sendable {
  case posture
  case blink
  /// Once-a-week summary toast — a weekly schedule, not an interval;
  /// `KindState.nextDue` for it is maintained by `WeeklyDigest`.
  case digest

  var eventKind: String { "nudge_sent" }

  var defaultTitle: String {
    switch self {
    case .posture:
      return "Posture check"
    case .blink:
      return "Blink break"
    case .digest:
      return "Weekly digest"
    }
  }
}

public struct WellnessNudge: Equatable, Sendable {
  public let kind: WellnessNudgeKind
  public let title: String
  public let body: String
  public let at: Date

  public init(kind: WellnessNudgeKind, body: String, at: Date) {
    self.kind = kind
    self.title = kind.defaultTitle
    self.body = body
    self.at = at
  }
}

public struct WellnessContext: Equatable, Sendable {
  public let schedulerPhase: GazeKeeperPhase
  public let pausedByUser: Bool
  public let pausedByDetector: Bool

  public init(
    schedulerPhase: GazeKeeperPhase, pausedByUser: Bool, pausedByDetector: Bool
  ) {
    self.schedulerPhase = schedulerPhase
    self.pausedByUser = pausedByUser
    self.pausedByDetector = pausedByDetector
  }

  func suppresses(_ kind: WellnessNudgeKind) -> Bool {
    switch schedulerPhase {
    case .breaking, .headsUp:
      return true
    case .idle, .cooldown:
      if pausedByDetector { return true }
      // A user pause is "leave me alone": posture nudges and the digest
      // hold; blink keeps firing — it's a two-second micro-rest and the
      // lightest touch.
      if pausedByUser, kind == .posture || kind == .digest { return true }
      return false
    }
  }
}

public struct WellnessSnapshot: Equatable, Sendable {
  public let enabled: Bool
  public let nextPostureAt: Date
  public let nextBlinkAt: Date
  public let lastPostureAt: Date?
  public let lastBlinkAt: Date?
  public let sentPostureCount: Int
  public let sentBlinkCount: Int
}

public final class WellnessCadence {

  public static let defaultPostureBody =
    "Time to reset your posture. Sit tall, roll your shoulders back."
  public static let defaultBlinkBody =
    "Give your eyes a blink break. Close them slowly for a few seconds."

  private struct KindState {
    var nextDue: Date
    var lastSentAt: Date?
    var sentCount = 0

    static func fresh(
      _ kind: WellnessNudgeKind, settings: GKSettingsV1, at now: Date,
      calendar: Calendar
    ) -> KindState {
      if kind == .digest {
        return KindState(nextDue: WeeklyDigest.nextDelivery(from: now, calendar: calendar))
      }
      let interval = Self.intervalSeconds(kind, in: settings)
      return KindState(nextDue: now.addingTimeInterval(interval))
    }

    static func intervalSeconds(
      _ kind: WellnessNudgeKind, in settings: GKSettingsV1
    ) -> TimeInterval {
      let minutes: Int
      switch kind {
      case .posture:
        minutes = settings.wellness.postureMinutes
      case .blink:
        minutes = settings.wellness.blinkMinutes
      case .digest:
        // Not interval-scheduled — `fresh` and the tick reschedule use
        // `WeeklyDigest.nextDelivery`; this value only feeds the
        // settings-shrink floor in `updateSettings`.
        return 7 * 86_400
      }
      return TimeInterval(GazeKeeperSettings.clamp(minutes, to: 1...1440)) * 60
    }
  }

  private var settings: GKSettingsV1
  private var states: [WellnessNudgeKind: KindState]
  private let calendar: Calendar

  public convenience init(settings: GKSettingsV1, now: Date) {
    self.init(settings: settings, now: now, calendar: .current)
  }

  public init(settings: GKSettingsV1, now: Date, calendar: Calendar) {
    self.settings = settings
    self.calendar = calendar
    self.states = [
      .posture: KindState.fresh(.posture, settings: settings, at: now, calendar: calendar),
      .blink: KindState.fresh(.blink, settings: settings, at: now, calendar: calendar),
      .digest: KindState.fresh(.digest, settings: settings, at: now, calendar: calendar),
    ]
  }

  public func updateSettings(_ newSettings: GKSettingsV1, at now: Date) {
    let wasEnabled = settings.wellness.enabled
    settings = newSettings
    guard newSettings.wellness.enabled else { return }
    if !wasEnabled {
      for kind in WellnessNudgeKind.allCases {
        states[kind] = KindState.fresh(kind, settings: newSettings, at: now, calendar: calendar)
      }
      return
    }
    for kind in WellnessNudgeKind.allCases {
      guard var state = states[kind] else { continue }
      state.nextDue = min(
        state.nextDue,
        now.addingTimeInterval(
          KindState.intervalSeconds(kind, in: newSettings)))
      states[kind] = state
    }
  }

  public func tick(at now: Date, context: WellnessContext) -> [WellnessNudge] {
    guard settings.wellness.enabled else { return [] }
    let quietHours = settings.wellness.quietHours
    var nudges: [WellnessNudge] = []
    for kind in WellnessNudgeKind.allCases {
      guard var state = states[kind], now >= state.nextDue else { continue }
      if kind == .digest {
        guard settings.wellness.weeklyDigest else { continue }
        // Same-day only: a due from a missed Monday must not fire Tuesday.
        guard calendar.isDate(now, inSameDayAs: state.nextDue) else {
          state.nextDue = nextMonday(after: now)
          states[kind] = state
          continue
        }
      }
      if context.suppresses(kind) || quietHours.suppresses(at: now, calendar: calendar) {
        // Withheld, not dropped: the due stays pending so exactly one nudge
        // per kind fires when suppression lifts — the coalesce semantics the
        // plan specifies for quiet-hours endings.
        continue
      }
      nudges.append(WellnessNudge(kind: kind, body: messageBody(for: kind), at: now))
      state.lastSentAt = now
      state.sentCount += 1
      state.nextDue =
        kind == .digest
        ? nextMonday(after: now)
        : now.addingTimeInterval(KindState.intervalSeconds(kind, in: settings))
      states[kind] = state
    }
    return nudges
  }

  /// The Monday after `now`'s day — delivery rescheduling after a fire or
  /// a missed window always lands on a *future* Monday 09:00.
  private func nextMonday(after now: Date) -> Date {
    let tomorrow =
      calendar.date(byAdding: .day, value: 1, to: now)
      ?? now.addingTimeInterval(86_400)
    return WeeklyDigest.nextDelivery(from: tomorrow, calendar: calendar)
  }

  /// Seed a delivery already in the persisted log (e.g., after relaunch
  /// on the same Monday) so the toast can't fire twice.
  public func noteDelivered(_ kind: WellnessNudgeKind, at date: Date) {
    guard kind == .digest else { return }
    guard var state = states[kind] else { return }
    state.lastSentAt = date
    state.nextDue = nextMonday(after: date)
    states[kind] = state
  }

  private func messageBody(for kind: WellnessNudgeKind) -> String {
    let wellness = settings.wellness
    switch kind {
    case .posture:
      if let custom = wellness.postureMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
        !custom.isEmpty
      {
        return custom
      }
      return Self.defaultPostureBody
    case .blink:
      if let custom = wellness.blinkMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
        !custom.isEmpty
      {
        return custom
      }
      return Self.defaultBlinkBody
    case .digest:
      // Composed by the controller — it owns the event log.
      return ""
    }
  }

  public func snapshot() -> WellnessSnapshot {
    let posture =
      states[.posture]
      ?? KindState.fresh(.posture, settings: settings, at: .distantPast, calendar: calendar)
    let blink =
      states[.blink]
      ?? KindState.fresh(.blink, settings: settings, at: .distantPast, calendar: calendar)
    return WellnessSnapshot(
      enabled: settings.wellness.enabled,
      nextPostureAt: posture.nextDue,
      nextBlinkAt: blink.nextDue,
      lastPostureAt: posture.lastSentAt,
      lastBlinkAt: blink.lastSentAt,
      sentPostureCount: posture.sentCount,
      sentBlinkCount: blink.sentCount)
  }

  static func intervalSeconds(_ kind: WellnessNudgeKind, in settings: GKSettingsV1) -> TimeInterval
  {
    KindState.intervalSeconds(kind, in: settings)
  }
}
