import Foundation

/// Every event the scheduler can emit, with the persisted wire string as its
/// raw value. Typed so a misspelled kind is a compile error, not a silently
/// dropped score/log entry.
public struct SchedulerEvent: Equatable, Sendable {
  public let kind: BreakEventKind
  public let reason: String?
  public let at: Date
  /// Runtime metadata: the due/break this event describes is a long one.
  /// Not persisted — `LoggedEvent` keeps its fixed wire fields.
  public let long: Bool

  public init(kind: BreakEventKind, reason: String? = nil, at: Date, long: Bool = false) {
    self.kind = kind
    self.reason = reason
    self.at = at
    self.long = long
  }
}

public enum GazeKeeperPhase: String, Codable, Equatable, Sendable {
  case idle
  case headsUp
  case breaking
  case cooldown
}

public struct SchedulerState: Equatable, Sendable {
  public var phase: GazeKeeperPhase
  public var phaseStartedAt: Date
  public var nextDue: Date
  public var breakEndsAt: Date?
  public var pausedByUser: Bool
  public var pausedByDetector: Bool
  /// A Focus mode holds this for its whole span; it never shares
  /// `pausedByUser`, so the two never stomp each other's resume.
  public var pausedByFocus: Bool
  public var lastPostponeReason: String?
  public var pausedRemaining: TimeInterval?
  public var breaksStarted: Int
  public var isAway: Bool
  /// Set only while `pausedByUser` — the wall-clock instant a timed pause
  /// lifts. Nil means indefinite.
  public var pausedUntil: Date?
  /// User snoozes consumed on the current due; resets when the due cycle
  /// ends (start, resolve, natural break, skip).
  public var snoozesUsed: Int
  /// The break currently on screen is a long one — drives the overlay's
  /// message pool and total duration.
  public var currentBreakIsLong: Bool
  /// Length this break was scheduled for. Pause/resume shifts
  /// `breakEndsAt` but never this, so the overlay ring keeps its scale.
  public var currentBreakSeconds: Int

  public init(
    phase: GazeKeeperPhase,
    phaseStartedAt: Date,
    nextDue: Date,
    breakEndsAt: Date? = nil,
    pausedByUser: Bool = false,
    pausedByDetector: Bool = false,
    pausedByFocus: Bool = false,
    lastPostponeReason: String? = nil,
    pausedRemaining: TimeInterval? = nil,
    breaksStarted: Int = 0,
    isAway: Bool = false,
    pausedUntil: Date? = nil,
    snoozesUsed: Int = 0,
    currentBreakIsLong: Bool = false,
    currentBreakSeconds: Int = 0
  ) {
    self.phase = phase
    self.phaseStartedAt = phaseStartedAt
    self.nextDue = nextDue
    self.breakEndsAt = breakEndsAt
    self.pausedByUser = pausedByUser
    self.pausedByDetector = pausedByDetector
    self.pausedByFocus = pausedByFocus
    self.lastPostponeReason = lastPostponeReason
    self.pausedRemaining = pausedRemaining
    self.breaksStarted = breaksStarted
    self.isAway = isAway
    self.pausedUntil = pausedUntil
    self.snoozesUsed = snoozesUsed
    self.currentBreakIsLong = currentBreakIsLong
    self.currentBreakSeconds = currentBreakSeconds
  }

  public func effectiveRemaining(from now: Date) -> TimeInterval {
    if isPaused() { return pausedRemaining ?? 0 }
    return max(0, nextDue.timeIntervalSince(now))
  }

  public func effectiveNextDue(from now: Date) -> Date {
    if isPaused() { return now.addingTimeInterval(pausedRemaining ?? 0) }
    return nextDue
  }

  public func isPaused() -> Bool {
    pausedByUser || pausedByDetector || pausedByFocus
  }
}

public struct SchedulerSnapshot: Equatable, Sendable {
  public let state: SchedulerState
  public let settings: GKSettingsV1
  public let events: [SchedulerEvent]

  public init(state: SchedulerState, settings: GKSettingsV1, events: [SchedulerEvent]) {
    self.state = state
    self.settings = settings
    self.events = events
  }
}

public final class Scheduler {

  private var state: SchedulerState
  private var settings: GKSettingsV1
  private var log: [SchedulerEvent]
  private let calendar: Calendar
  private let idleProvider: any GKIdleProviding
  private let lullProvider: any GKInputLullProviding
  private var overrideIdleStorage: TimeInterval?
  private let overrideIdleSeconds: TimeInterval?
  private var awaySince: Date?
  private var idleBreakConsumed = false
  /// Meeting starts the engine last pushed in. Only consulted when
  /// `settings.calendarAware` is on — see `adjustDueForCalendar`.
  private var meetingStarts: [Date] = []

  public convenience init(
    settings: GKSettingsV1, now: Date, calendar: Calendar = .current
  ) {
    self.init(
      settings: settings, now: now, calendar: calendar,
      idleProvider: ZeroIdleProvider(), overrideIdleSeconds: nil,
      lullProvider: ZeroLullProvider())
  }

  public init(
    settings: GKSettingsV1, now: Date, calendar: Calendar = .current,
    idleProvider: any GKIdleProviding, overrideIdleSeconds: TimeInterval? = nil,
    priorBreaksStarted: Int = 0,
    lullProvider: any GKInputLullProviding = ZeroLullProvider()
  ) {
    self.settings = settings
    self.state = SchedulerState(
      phase: .idle, phaseStartedAt: now,
      nextDue: now.addingTimeInterval(TimeInterval(settings.intervalMinutes) * 60),
      breaksStarted: priorBreaksStarted)
    self.log = []
    self.calendar = calendar
    self.idleProvider = idleProvider
    self.lullProvider = lullProvider
    self.overrideIdleStorage = overrideIdleSeconds
    self.overrideIdleSeconds = overrideIdleSeconds
  }

  public func tick(_ now: Date) -> [SchedulerEvent] {
    return advanceState(to: now)
  }

  /// `duration` overrides the configured length for one-off runs —
  /// onboarding's "try a short break" uses it. It's a real break: it
  /// logs `break_started` and counts exactly like any other.
  public func triggerBreak(at now: Date, duration: TimeInterval? = nil) -> [SchedulerEvent] {
    guard !state.isPaused() else { return [] }
    guard state.phase != .breaking else { return [] }
    return enterBreaking(at: now, duration: duration)
  }

  public func skip(at now: Date, reason: String = "user") -> SchedulerEvent? {
    guard state.phase == .breaking else { return nil }
    let event = SchedulerEvent(kind: .breakSkipped, reason: reason, at: now)
    log.append(event)
    enterCooldown(at: now)
    return event
  }

  /// "Skip next break" — the menu item that cancels the upcoming due.
  /// With a due already open (heads-up) this is an ordinary skip; before
  /// it, a skip-ahead that pushes the cadence a full interval out.
  @discardableResult
  public func skipNextBreak(at now: Date) -> SchedulerEvent? {
    switch state.phase {
    case .breaking:
      return nil
    case .headsUp:
      let event = SchedulerEvent(kind: .breakSkipped, reason: "user", at: now)
      log.append(event)
      enterCooldown(at: now)
      return event
    case .idle, .cooldown:
      let event = SchedulerEvent(kind: .breakSkipped, reason: "skipped_ahead", at: now)
      log.append(event)
      state.snoozesUsed = 0
      state.nextDue = adjustDueForCalendar(now.addingTimeInterval(intervalSeconds), at: now)
      if state.phase == .cooldown {
        state.phase = .idle
        state.phaseStartedAt = now
      }
      return event
    }
  }

  public func completeBreak(at now: Date) -> SchedulerEvent? {
    guard state.phase == .breaking, let end = state.breakEndsAt, now >= end else { return nil }
    let event = SchedulerEvent(kind: breakEndKind(at: now), at: now)
    log.append(event)
    enterCooldown(at: now)
    return event
  }

  /// Input during the break means the user worked through it — the due
  /// still resolves, but the event is honest about the rest not happening.
  private func breakEndKind(at now: Date) -> BreakEventKind {
    let elapsed = now.timeIntervalSince(state.phaseStartedAt)
    return lullProvider.secondsSinceLastInput() < elapsed ? .breakWorked : .breakTaken
  }

  @discardableResult
  public func postpone(seconds: TimeInterval, reason: String = "user", at now: Date)
    -> SchedulerEvent?
  {
    if reason == "user", settings.snoozeLimit > 0,
      state.snoozesUsed >= settings.snoozeLimit
    {
      let exhausted = SchedulerEvent(kind: .snoozeExhausted, reason: reason, at: now)
      log.append(exhausted)
      return exhausted
    }
    if reason == "user" { state.snoozesUsed += 1 }
    let clampedSeconds = Self.clampedPostponeSeconds(seconds)
    let event = SchedulerEvent(kind: .breakPostponed, reason: reason, at: now)
    log.append(event)
    state.phase = .idle
    state.breakEndsAt = nil
    if state.isPaused() {
      state.pausedRemaining = clampedSeconds
    } else {
      state.pausedRemaining = nil
    }
    state.nextDue = now.addingTimeInterval(clampedSeconds)
    state.phaseStartedAt = now
    state.lastPostponeReason = reason
    return event
  }

  public static func clampedPostponeSeconds(_ seconds: TimeInterval) -> TimeInterval {
    min(max(1, seconds), maxPostponeSeconds)
  }

  public static let maxPostponeSeconds: TimeInterval = 24 * 3600

  /// Returns events produced by the pause transition. Pausing during a break
  /// never traps the user behind the overlay: it ends the break with a
  /// `break_interrupted` event and drops into cooldown, still paused.
  @discardableResult
  public func setPaused(
    byUser: Bool? = nil, byDetector: Bool? = nil, byFocus: Bool? = nil, at now: Date
  ) -> [SchedulerEvent] {
    if let userPaused = byUser {
      state.pausedByUser = userPaused
      if !userPaused { state.pausedUntil = nil }
    }
    if let detectorPaused = byDetector {
      state.pausedByDetector = detectorPaused
    }
    if let focusPaused = byFocus {
      state.pausedByFocus = focusPaused
    }
    if state.isPaused() {
      if state.phase == .breaking {
        let reason = byUser == true ? "user" : byFocus == true ? "focus" : "detector"
        let event = SchedulerEvent(kind: .breakInterrupted, reason: reason, at: now)
        log.append(event)
        enterCooldown(at: now)
        freezeRemaining(at: now)
        return [event]
      }
      freezeRemaining(at: now)
    } else {
      resumeSchedule(at: now)
    }
    return []
  }

  /// Pause for a bounded span — the menu's 30m/1h/until-tomorrow options.
  /// Behaves exactly like a user pause that lifts itself.
  @discardableResult
  public func pauseUser(until deadline: Date, at now: Date) -> [SchedulerEvent] {
    state.pausedUntil = deadline
    return setPaused(byUser: true, at: now)
  }

  private func freezeRemaining(at now: Date) {
    guard state.pausedRemaining == nil else { return }
    switch state.phase {
    case .breaking:
      let frozen = max(1, (state.breakEndsAt ?? now).timeIntervalSince(now))
      state.pausedRemaining = frozen
      state.breakEndsAt = now.addingTimeInterval(frozen)
      state.nextDue = adjustDueForCalendar(
        now.addingTimeInterval(frozen + intervalSeconds), at: now)
    default:
      state.pausedRemaining = max(1, state.nextDue.timeIntervalSince(now))
    }
  }

  private func resumeSchedule(at now: Date) {
    guard let frozen = state.pausedRemaining else {
      if state.nextDue < now { recomputeNextDue(from: now) }
      return
    }
    state.pausedRemaining = nil
    switch state.phase {
    case .breaking where state.breakEndsAt != nil:
      state.breakEndsAt = now.addingTimeInterval(frozen)
      state.nextDue = adjustDueForCalendar(
        now.addingTimeInterval(frozen + intervalSeconds), at: now)
      state.phaseStartedAt = now
    default:
      state.nextDue = adjustDueForCalendar(now.addingTimeInterval(frozen), at: now)
      state.phaseStartedAt = now
    }
  }

  public func updateSettings(_ newSettings: GKSettingsV1, at now: Date) {
    settings = newSettings
    if state.phase == .idle || state.phase == .cooldown {
      recomputeNextDue(from: now)
    }
  }

  public var currentSettings: GKSettingsV1 {
    return settings
  }

  /// The earliest time `tick` could produce a phase change. Nil while paused:
  /// a frozen schedule has no time-driven transitions, only resume events.
  public func nextTransition(after now: Date) -> Date? {
    guard !state.isAway else { return nil }
    if state.isPaused() {
      // A timed user pause has exactly one time edge: its lift.
      return state.pausedByUser ? state.pausedUntil : nil
    }
    switch state.phase {
    case .cooldown:
      return state.phaseStartedAt.addingTimeInterval(TimeInterval(settings.cooldownSeconds))
    case .idle:
      return state.nextDue
    case .headsUp:
      if now >= state.nextDue, lullBlocksBreak(at: now) {
        return now.addingTimeInterval(0.5)
      }
      return state.nextDue
    case .breaking:
      return state.breakEndsAt
    }
  }

  public func snapshot(at now: Date) -> SchedulerSnapshot {
    return SchedulerSnapshot(state: state, settings: settings, events: log)
  }

  public func currentState() -> SchedulerState {
    return state
  }

  public func currentIdleSeconds() -> TimeInterval {
    if let live = overrideIdleStorage { return live }
    if let overrideIdleSeconds { return overrideIdleSeconds }
    return idleProvider.currentIdleSeconds()
  }

  public func setOverrideIdleSeconds(_ seconds: TimeInterval?) {
    overrideIdleStorage = seconds
  }

  /// Sleep, screen-sleep and session lock funnel here through the engine's
  /// `.awayBegan`/`.awayEnded` inputs. While away the machine is inert — no
  /// transitions, no nudges, no wakes.
  public func awayBegan(at now: Date) {
    if awaySince == nil { awaySince = now }
    state.isAway = true
  }

  /// On return: an absence of at least one break length is a natural break —
  /// reset the cadence. A shorter absence earns a 60-second grace in which
  /// nothing can come due, so waking never fires a break in the user's face.
  @discardableResult
  public func awayEnded(at now: Date) -> [SchedulerEvent] {
    let awayFor = awaySince.map { now.timeIntervalSince($0) } ?? 0
    awaySince = nil
    state.isAway = false
    if awayFor >= TimeInterval(settings.breakSeconds) {
      return [recordNaturalBreak(reason: "away", at: now)]
    }
    let graceUntil = now.addingTimeInterval(Self.resumeGraceSeconds)
    switch state.phase {
    case .idle, .headsUp:
      if state.nextDue < graceUntil { state.nextDue = graceUntil }
    case .cooldown, .breaking:
      break
    }
    return []
  }

  public static let resumeGraceSeconds: TimeInterval = 60

  /// The break-start hold: no break lands while a key or mouse event is
  /// fresher than `lullWindowSeconds`, capped at 30 s past the heads-up so
  /// a stuck key can never starve the break out.
  private func lullBlocksBreak(at now: Date) -> Bool {
    let holdDeadline =
      state.phaseStartedAt
      .addingTimeInterval(
        TimeInterval(settings.headsUpSeconds) + Self.lullHoldCapSeconds)
    guard now < holdDeadline else { return false }
    return lullProvider.secondsSinceLastInput() < Self.lullWindowSeconds
  }

  public static let lullWindowSeconds: TimeInterval = 2
  public static let lullHoldCapSeconds: TimeInterval = 30

  private func idleSeconds(at now: Date) -> TimeInterval {
    if state.pausedRemaining != nil { return 0 }
    return currentIdleSeconds()
  }

  private func advanceState(to now: Date) -> [SchedulerEvent] {
    guard !state.isAway else { return [] }
    if state.pausedByUser, let until = state.pausedUntil, now >= until {
      state.pausedByUser = false
      state.pausedUntil = nil
      resumeSchedule(at: now)
    }
    guard !state.isPaused() else {
      if state.phase == .breaking, let frozen = state.pausedRemaining {
        state.breakEndsAt = now.addingTimeInterval(frozen)
      }
      return []
    }
    let idle = idleSeconds(at: now)
    let naturalBreakSeconds = TimeInterval(settings.naturalBreakIdleMinutes * 60)
    if state.phase != .breaking, idle >= naturalBreakSeconds {
      if idleBreakConsumed {
        // Still resting — park the cadence a full interval out, quietly.
        if state.phase == .headsUp {
          state.phase = .idle
          state.phaseStartedAt = now
          state.breakEndsAt = nil
        }
        recomputeNextDue(from: now)
        return []
      }
      idleBreakConsumed = true
      return [recordNaturalBreak(reason: "idle", at: now)]
    }
    if idle < naturalBreakSeconds { idleBreakConsumed = false }
    switch state.phase {
    case .cooldown:
      if now.timeIntervalSince(state.phaseStartedAt) >= TimeInterval(settings.cooldownSeconds) {
        state.phase = .idle
        state.phaseStartedAt = now
        return advanceState(to: now)
      }
      return []
    case .idle:
      if now >= state.nextDue {
        if !officeHoursOpen(at: now) {
          return [recordPostpone(reason: "office_hours", at: now)]
        }
        if idle >= TimeInterval(GazeKeeperSettings.idleThresholdSeconds) {
          return [recordPostpone(reason: "idle", at: now)]
        }
        state.phase = .headsUp
        state.phaseStartedAt = now
        state.nextDue = now.addingTimeInterval(TimeInterval(settings.headsUpSeconds))
        let event = SchedulerEvent(kind: .breakDue, at: now, long: nextBreakIsLong)
        log.append(event)
        return [event]
      }
      return []
    case .headsUp:
      if now < state.nextDue { return [] }
      if !officeHoursOpen(at: now) {
        return [recordPostpone(reason: "office_hours", at: now)]
      }
      if idle >= idleThreshold {
        return [recordPostpone(reason: "idle", at: now)]
      }
      if lullBlocksBreak(at: now) { return [] }
      return enterBreaking(at: now)
    case .breaking:
      if let end = state.breakEndsAt, now >= end {
        let event = SchedulerEvent(kind: breakEndKind(at: now), at: now)
        log.append(event)
        enterCooldown(at: now)
        return [event]
      }
      return []
    }
  }

  /// Logs a postpone, resets the schedule, and returns the event so the caller
  /// can persist it. Reasons: "user", "idle", "office_hours".
  private func recordPostpone(reason: String, at now: Date) -> SchedulerEvent {
    let event = SchedulerEvent(kind: .breakPostponed, reason: reason, at: now)
    log.append(event)
    state.lastPostponeReason = reason
    if state.phase == .headsUp {
      state.phase = .idle
      state.phaseStartedAt = now
      state.breakEndsAt = nil
      state.pausedRemaining = nil
    }
    recomputeNextDue(from: now)
    return event
  }

  /// A rest the machine observed — away or deep idle — logged once per rest
  /// and treated like a taken break by the score. Resets the cadence.
  private func recordNaturalBreak(reason: String, at now: Date) -> SchedulerEvent {
    let event = SchedulerEvent(kind: .naturalBreak, reason: reason, at: now)
    log.append(event)
    state.phase = .idle
    state.phaseStartedAt = now
    state.breakEndsAt = nil
    state.pausedRemaining = nil
    state.nextDue = adjustDueForCalendar(now.addingTimeInterval(intervalSeconds), at: now)
    state.snoozesUsed = 0
    return event
  }

  /// Whether the break about to start (number `breaksStarted + 1`) is a
  /// long one. `longBreakEvery == 0` disables long breaks entirely.
  private var nextBreakIsLong: Bool {
    let every = settings.longBreakEvery
    guard every > 0 else { return false }
    return (state.breaksStarted + 1) % every == 0
  }

  private func enterBreaking(at now: Date, duration: TimeInterval? = nil) -> [SchedulerEvent] {
    let isLong = duration == nil && nextBreakIsLong
    state.phase = .breaking
    state.currentBreakIsLong = isLong
    state.phaseStartedAt = now
    state.breaksStarted += 1
    let length =
      duration ?? TimeInterval(isLong ? settings.longBreakSeconds : settings.breakSeconds)
    state.currentBreakSeconds = Int(length.rounded(.up))
    state.breakEndsAt = now.addingTimeInterval(length)
    state.snoozesUsed = 0
    let event = SchedulerEvent(kind: .breakStarted, at: now, long: isLong)
    log.append(event)
    return [event]
  }

  private func enterCooldown(at now: Date) {
    state.phase = .cooldown
    state.currentBreakIsLong = false
    state.phaseStartedAt = now
    state.breakEndsAt = nil
    state.pausedRemaining = nil
    state.nextDue = adjustDueForCalendar(now.addingTimeInterval(intervalSeconds), at: now)
  }

  private func recomputeNextDue(from now: Date) {
    state.nextDue = adjustDueForCalendar(now.addingTimeInterval(intervalSeconds), at: now)
  }

  /// Fresh meeting starts from the engine (calendar changed, or the
  /// setting toggled on). Re-runs the adjust on the pending due without
  /// resetting the cadence — a meeting that appeared under the pending
  /// due pulls it forward; a canceled one leaves the earlier time
  /// (conservative: an early break is never the harmful direction).
  public func updateMeetingStarts(_ starts: [Date], at now: Date) {
    meetingStarts = starts.sorted()
    guard settings.calendarAware else { return }
    guard state.phase == .idle || state.phase == .cooldown else { return }
    state.nextDue = adjustDueForCalendar(state.nextDue, at: now)
  }

  /// The calendar rule: a scheduled break never lands in the last two
  /// minutes before a meeting — it is pulled forward to three minutes
  /// before the start instead, leaving room for the heads-up and the
  /// break itself. Dues that land *inside* a meeting are untouched:
  /// detector signals own in-call behavior.
  private func adjustDueForCalendar(_ due: Date, at now: Date) -> Date {
    guard settings.calendarAware, !meetingStarts.isEmpty else { return due }
    for start in meetingStarts where start > now {
      if due >= start.addingTimeInterval(-120), due < start {
        return start.addingTimeInterval(-180)
      }
    }
    return due
  }

  private var intervalSeconds: TimeInterval {
    TimeInterval(settings.intervalMinutes * 60)
  }

  private var idleThreshold: TimeInterval {
    TimeInterval(GazeKeeperSettings.idleThresholdSeconds)
  }

  private func officeHoursOpen(at date: Date) -> Bool {
    guard settings.officeHours.enabled else { return true }
    let weekday = calendar.component(.weekday, from: date)
    guard settings.officeHours.days.contains(weekday) else { return false }
    let minute =
      calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    let start = settings.officeHours.startMinuteOfDay
    let end = settings.officeHours.endMinuteOfDay
    if start <= end {
      return minute >= start && minute < end
    }
    return minute >= start || minute < end
  }
}
