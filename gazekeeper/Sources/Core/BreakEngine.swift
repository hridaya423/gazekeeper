import Foundation

/// Everything that can drive the break schedule. The shell translates app
/// lifecycle, workspace, and user actions into inputs; the engine decides
/// what happened and reports it as output events.
public enum EngineInput {
  /// The wake timer fired; advance time-driven state.
  case tick(Date)
  /// The frontmost app sample changed.
  case detectorSignals(DetectorSignals)
  /// The user asked for a break now.
  /// `duration` overrides the configured break length for this one
  /// break (onboarding's short trial); nil uses settings.
  case triggerBreak(duration: TimeInterval?)
  /// The user skipped the current break (button, esc, or hotkey).
  case skip(reason: String)
  /// The user postponed the upcoming break.
  case postpone(seconds: TimeInterval)
  /// The break finished early (debug surface; production completion comes
  /// through `tick`).
  case completeBreak
  /// Pause toggles; each side is independent (user pause, detector pause).
  case setPaused(user: Bool?, detector: Bool?, focus: Bool? = nil)
  /// The menu's bounded pause — lifts itself at the deadline.
  case pauseUser(until: Date)
  /// "Skip next break": cancels the upcoming due and re-arms a full
  /// interval; with a due already open it is an ordinary skip.
  case skipNextBreak
  /// A committed settings value; applied to every subsystem at once.
  case settingsChanged(GKSettingsV1)
  /// A stats-only event the shell still wants through the single pipe.
  case menuRevealed(reason: String)
  /// The machine went away: sleep, screen-sleep, or session lock.
  case awayBegan
  /// The machine is back: wake or unlock.
  case awayEnded
  /// Upcoming meeting starts — the shell re-sends on EKEventStoreChanged,
  /// launch, and when the calendar-aware setting toggles on.
  case calendarChanged(starts: [Date])
}

/// One `handle` call's worth of consequences. `events` go to the stats log
/// and drive state side effects (chime, heads-up); `nudges` go to the
/// notification layer for delivery.
public struct EngineOutput {
  public var events: [SchedulerEvent] = []
  public var nudges: [WellnessNudge] = []
}

/// The domain core: scheduler, detectors, and wellness cadence behind one
/// imperative interface. The shell owns no scheduling logic — it feeds
/// inputs, performs the output side effects, and re-arms its timer to
/// `nextWakeup`.
@MainActor
public final class BreakEngine {

  public let clock: OffsetClock
  private let scheduler: Scheduler
  private let detectorEngine: DetectorEngine
  private let wellnessCadence: WellnessCadence
  private let lullProvider: any GKInputLullProviding
  private(set) var lastDetectorDecisions: [DetectorDecision] = []
  private var lastSignals: DetectorSignals?
  private var settings: GKSettingsV1

  public init(
    settings: GKSettingsV1,
    clock: OffsetClock,
    idleProvider: any GKIdleProviding,
    priorBreaksStarted: Int = 0,
    lullProvider: any GKInputLullProviding = ZeroLullProvider()
  ) {
    self.settings = settings
    self.clock = clock
    self.scheduler = Scheduler(
      settings: settings, now: clock.now(), idleProvider: idleProvider,
      priorBreaksStarted: priorBreaksStarted, lullProvider: lullProvider)
    self.detectorEngine = DetectorEngine(settings: settings)
    self.wellnessCadence = WellnessCadence(settings: settings, now: clock.now(), calendar: .current)
    self.lullProvider = lullProvider
  }

  public var snapshot: SchedulerSnapshot {
    scheduler.snapshot(at: clock.now())
  }

  public var currentSettings: GKSettingsV1 {
    settings
  }

  public var detectorDecisions: [DetectorDecision] {
    lastDetectorDecisions
  }

  /// Why the detector is holding a pause right now, or nil. Typed —
  /// the event log speaks `eventReason`; the App layer formats the
  /// menu string so app rules can show a resolved name.
  public var detectorPauseReason: DetectorReason? {
    detectorEngine.currentReason
  }

  public var wellnessSnapshot: WellnessSnapshot {
    wellnessCadence.snapshot()
  }

  /// Replays a digest delivery already in the persisted log so a
  /// same-Monday relaunch can't fire the toast twice.
  public func noteDigestDelivered(at date: Date) {
    wellnessCadence.noteDelivered(.digest, at: date)
  }

  public func currentIdleSeconds() -> TimeInterval {
    scheduler.currentIdleSeconds()
  }

  #if DEBUG
    public func injectIdle(seconds: TimeInterval) {
      scheduler.setOverrideIdleSeconds(max(0, seconds))
    }

  #endif

  /// The earliest time a `tick` could produce a transition or a nudge —
  /// the only deadline the shell's timer ever needs. A withheld nudge (due
  /// but suppressed) is never a candidate: it delivers on the first tick
  /// after suppression lifts, which is event-driven for pause/break and
  /// time-driven for quiet hours — so only the quiet window's end is.
  public func nextWakeup(now: Date) -> Date? {
    var candidates: [Date] = []
    if let transition = scheduler.nextTransition(after: now) {
      candidates.append(transition)
    }
    if settings.wellness.enabled {
      let state = scheduler.currentState()
      guard !state.isAway else { return candidates.min() }
      let context = WellnessContext(
        schedulerPhase: state.phase,
        pausedByUser: state.pausedByUser,
        pausedByDetector: state.pausedByDetector)
      let quietHours = settings.wellness.quietHours
      if quietHours.suppresses(at: now) {
        if let lift = quietHours.nextUnsuppressedTime(after: now) {
          candidates.append(lift)
        }
      } else {
        let nudges = wellnessCadence.snapshot()
        let nextDue: [WellnessNudgeKind: Date] = [
          .posture: nudges.nextPostureAt,
          .blink: nudges.nextBlinkAt,
        ]
        for kind in WellnessNudgeKind.allCases where !context.suppresses(kind) {
          if let due = nextDue[kind] {
            if due <= now, inputIsHot {
              // A lull-held nudge keeps a due in the past. Waking at that
              // stale instant would spin the rearm loop — substitute a
              // bounded recheck instead.
              candidates.append(now.addingTimeInterval(Self.nudgeLullRecheck))
            } else {
              candidates.append(due)
            }
          }
        }
      }
    }
    return candidates.min()
  }

  @discardableResult
  public func handle(_ input: EngineInput) -> EngineOutput {
    switch input {
    case .tick(let now):
      var output = EngineOutput(events: scheduler.tick(now))
      deliverWellness(at: now, into: &output)
      return output

    case .detectorSignals(let signals):
      let now = clock.now()
      lastSignals = signals
      var output = EngineOutput()
      guard let decision = detectorEngine.process(signals: signals, at: now) else {
        return output
      }
      lastDetectorDecisions = [decision]
      switch decision.action {
      case .paused:
        output.events.append(
          contentsOf: scheduler.setPaused(byUser: nil, byDetector: true, at: now))
      case .resumed:
        output.events.append(
          contentsOf: scheduler.setPaused(byUser: nil, byDetector: false, at: now))
      }
      output.events.append(
        SchedulerEvent(
          kind: decision.eventKind, reason: decision.reason.eventReason, at: decision.at))
      return output

    case .triggerBreak(let duration):
      return EngineOutput(
        events: scheduler.triggerBreak(at: clock.now(), duration: duration))

    case .skip(let reason):
      var output = EngineOutput()
      if let event = scheduler.skip(at: clock.now(), reason: reason) {
        output.events.append(event)
      }
      return output

    case .postpone(let seconds):
      var output = EngineOutput()
      if let event = scheduler.postpone(seconds: seconds, at: clock.now()) {
        output.events.append(event)
      }
      return output

    case .pauseUser(let deadline):
      return EngineOutput(events: scheduler.pauseUser(until: deadline, at: clock.now()))
    case .skipNextBreak:
      var output = EngineOutput()
      if let event = scheduler.skipNextBreak(at: clock.now()) {
        output.events.append(event)
      }
      return output
    case .setPaused(let user, let detector, let focus):
      return EngineOutput(
        events: scheduler.setPaused(
          byUser: user, byDetector: detector, byFocus: focus, at: clock.now()))

    case .settingsChanged(let updated):
      settings = updated
      scheduler.updateSettings(updated, at: clock.now())
      detectorEngine.updateSettings(updated)
      wellnessCadence.updateSettings(updated, at: clock.now())
      // Detector state is settings-sensitive (app rules, per-signal
      // enables) — re-evaluate the last snapshot so an edit takes
      // effect immediately instead of on the next hardware flip.
      guard let signals = lastSignals else { return EngineOutput() }
      var output = EngineOutput()
      guard let decision = detectorEngine.process(signals: signals, at: clock.now())
      else { return output }
      lastDetectorDecisions = [decision]
      switch decision.action {
      case .paused:
        output.events.append(
          contentsOf: scheduler.setPaused(byUser: nil, byDetector: true, at: clock.now()))
      case .resumed:
        output.events.append(
          contentsOf: scheduler.setPaused(byUser: nil, byDetector: false, at: clock.now()))
      }
      output.events.append(
        SchedulerEvent(
          kind: decision.eventKind, reason: decision.reason.eventReason, at: clock.now()))
      return output

    case .completeBreak:
      var output = EngineOutput()
      if let event = scheduler.completeBreak(at: clock.now()) {
        output.events.append(event)
      }
      return output

    case .awayBegan:
      scheduler.awayBegan(at: clock.now())
      return EngineOutput()
    case .awayEnded:
      return EngineOutput(events: scheduler.awayEnded(at: clock.now()))
    case .calendarChanged(let starts):
      scheduler.updateMeetingStarts(starts, at: clock.now())
      return EngineOutput()
    case .menuRevealed(let reason):
      return EngineOutput(
        events: [SchedulerEvent(kind: .menuRevealed, reason: reason, at: clock.now())])
    }
  }

  /// True while the user is mid-keystroke or mid-drag. A break already
  /// waits for a lull (Scheduler.lullWindowSeconds); nudges get the same
  /// tact — a toast over active typing is exactly the interruption the
  /// product exists to prevent.
  private var inputIsHot: Bool {
    lullProvider.secondsSinceLastInput() < Scheduler.lullWindowSeconds
  }

  /// Recheck interval while a due nudge is held for input — short enough
  /// to feel instant when the hands lift, bounded so it never spins.
  private static let nudgeLullRecheck: TimeInterval = 1

  private func deliverWellness(at now: Date, into output: inout EngineOutput) {
    // Held, not dropped: dues stay pending so the nudge delivers on the
    // first tick after the lull — matching the coalesce semantics of
    // every other suppression in WellnessCadence.tick.
    guard !inputIsHot else { return }
    let state = scheduler.currentState()
    let context = WellnessContext(
      schedulerPhase: state.phase,
      pausedByUser: state.pausedByUser,
      pausedByDetector: state.pausedByDetector)
    for nudge in wellnessCadence.tick(at: now, context: context) {
      output.nudges.append(nudge)
      output.events.append(
        SchedulerEvent(kind: .nudgeSent, reason: nudge.kind.rawValue, at: nudge.at))
    }
  }
}
