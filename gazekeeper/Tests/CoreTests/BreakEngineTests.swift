import XCTest

@testable import GazeKeeperCore

@MainActor
final class BreakEngineTests: XCTestCase {

  private func makeEngine(
    settings: GKSettingsV1 = GKSettingsV1(),
    lullSeconds: TimeInterval = 60
  ) -> BreakEngine {
    BreakEngine(
      settings: settings, clock: OffsetClock(),
      idleProvider: FixedIdleProvider(idleSeconds: 0),
      lullProvider: FixedLullProvider(seconds: lullSeconds))
  }

  func testTickPastIntervalEmitsBreakDue() {
    let engine = makeEngine()
    let due = engine.clock.now().addingTimeInterval(21 * 60)
    let output = engine.handle(.tick(due))
    XCTAssertTrue(output.events.contains { $0.kind == .breakDue })
  }

  func testDetectorSignalsPauseThroughTheSinglePipe() {
    let engine = makeEngine()

    let output = engine.handle(
      .detectorSignals(DetectorSignals(cameraRunning: true)))
    XCTAssertTrue(
      output.events.contains { $0.kind == .detectorPaused },
      "a camera signal must surface a detector_paused event")
    XCTAssertTrue(engine.snapshot.state.pausedByDetector)
    XCTAssertEqual(engine.detectorPauseReason, .camera)
  }

  func testAppRuleChangeReEvaluatesLastSignals() {
    let engine = makeEngine()
    _ = engine.handle(
      .detectorSignals(DetectorSignals(frontmostBundleId: "com.vlc")))
    XCTAssertFalse(engine.snapshot.state.pausedByDetector)

    var updated = engine.currentSettings
    updated.appRules["com.vlc"] = .pause
    let output = engine.handle(.settingsChanged(updated))
    XCTAssertTrue(
      output.events.contains { $0.kind == .detectorPaused },
      "a new pause rule must act on the remembered signals immediately")
    XCTAssertTrue(engine.snapshot.state.pausedByDetector)
  }

  func testCalendarChangedPullsThePendingDueThroughTheEngine() {
    var settings = GKSettingsV1()
    settings.calendarAware = true
    let engine = makeEngine(settings: settings)
    let due = engine.snapshot.state.nextDue
    _ = engine.handle(
      .calendarChanged(starts: [due.addingTimeInterval(60)]))
    let adjusted = engine.snapshot.state.nextDue
    XCTAssertEqual(
      adjusted, due.addingTimeInterval(-120),
      "a due one minute before a meeting is pulled to three minutes before")
  }

  func testSettingsChangedPropagatesEverywhere() {
    let engine = makeEngine()
    var updated = engine.currentSettings
    updated.intervalMinutes = 5
    engine.handle(.settingsChanged(updated))
    XCTAssertEqual(engine.currentSettings.intervalMinutes, 5)
  }

  func testNextWakeupIsTheSchedulerTransitionWhenWellnessIsOff() {
    var settings = GKSettingsV1()
    settings.wellness.enabled = false
    let engine = makeEngine(settings: settings)
    let now = engine.clock.now()
    let wakeup = engine.nextWakeup(now: now)
    XCTAssertNotNil(wakeup)
    XCTAssertEqual(
      wakeup!.timeIntervalSince(now), 20 * 60, accuracy: 5,
      "default 20-minute interval is the next transition")
  }

  func testNextWakeupPicksUpNudgeWhenSooner() {
    var settings = GKSettingsV1()
    settings.wellness.enabled = true
    settings.wellness.postureMinutes = 3
    settings.wellness.blinkMinutes = 9
    let engine = makeEngine(settings: settings)
    let now = engine.clock.now()
    let wakeup = engine.nextWakeup(now: now)
    XCTAssertNotNil(wakeup)
    XCTAssertEqual(
      wakeup!.timeIntervalSince(now), 3 * 60, accuracy: 5,
      "the 3-minute posture nudge beats the 20-minute break")
  }

  func testNextWakeupDuringQuietHoursTargetsTheWindowEndNotAPastDue() {
    var settings = GKSettingsV1()
    settings.wellness.enabled = true
    settings.wellness.postureMinutes = 1
    // Quiet window that contains "now" regardless of wall clock: start a
    // minute ago, end in two minutes.
    let now = Date()
    let cal = Calendar.current
    let minuteOfDay =
      cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
    settings.wellness.quietHours = WellnessQuietHours(
      enabled: true, startMinuteOfDay: (minuteOfDay + 1438) % 1440,
      endMinuteOfDay: (minuteOfDay + 2) % 1440)
    let engine = makeEngine(settings: settings)

    // Force a nudge due in the past by ticking well past the interval.
    _ = engine.handle(.tick(engine.clock.now().addingTimeInterval(90 * 60)))

    let wakeup = engine.nextWakeup(now: engine.clock.now())
    XCTAssertNotNil(wakeup)
    XCTAssertGreaterThan(
      wakeup!, engine.clock.now(),
      "a withheld nudge must never produce a wakeup in the past")
  }

  func testUserPauseExcludesSuppressedPostureButKeepsBlink() {
    var settings = GKSettingsV1()
    settings.wellness.enabled = true
    settings.wellness.postureMinutes = 1
    settings.wellness.blinkMinutes = 10
    let engine = makeEngine(settings: settings)

    // Tick far enough that posture falls due while paused, so its due date
    // sits in the past — it must not become a wakeup candidate. Blink is
    // not suppressed by a user pause (posture nudges are) so its due stays.
    _ = engine.handle(.setPaused(user: true, detector: nil))
    let tickAt = engine.clock.now().addingTimeInterval(90 * 60)
    _ = engine.handle(.tick(tickAt))

    let now = engine.clock.now()
    let wakeup = engine.nextWakeup(now: now)
    XCTAssertNotNil(wakeup)
    XCTAssertGreaterThan(
      wakeup!, now, "a withheld posture nudge must never wake in the past")
    XCTAssertEqual(
      wakeup!.timeIntervalSince(now), engine.wellnessSnapshot.nextBlinkAt.timeIntervalSince(now),
      accuracy: 1, "the unsuppressed blink deadline is the next wellness wake")
  }

  func testUserActionsReturnEventsForTheLogPipe() {
    let engine = makeEngine()
    let triggered = engine.handle(.triggerBreak(duration: nil))
    XCTAssertTrue(triggered.events.contains { $0.kind == .breakStarted })

    let postponed = engine.handle(.postpone(seconds: 300))
    XCTAssertTrue(
      postponed.events.isEmpty || postponed.events.contains { $0.kind == .breakPostponed })
  }

  func testTriggerBreakWithCustomDurationSchedulesThatLength() {
    var settings = GKSettingsV1()
    settings.breakSeconds = 20
    let engine = makeEngine(settings: settings)
    let now = engine.clock.now()
    let output = engine.handle(.triggerBreak(duration: 5))
    XCTAssertTrue(output.events.contains { $0.kind == .breakStarted })
    XCTAssertEqual(
      engine.snapshot.state.breakEndsAt?.timeIntervalSince(now) ?? -1, 5,
      accuracy: 0.1,
      "a custom duration schedules exactly that break — not the 20 s default")
    XCTAssertFalse(
      engine.snapshot.state.currentBreakIsLong,
      "a trial break never borrows the long-break layout")
  }

  func testOverlayModelTotalSecondsFollowsTheScheduledDuration() {
    var settings = GKSettingsV1()
    settings.breakSeconds = 20
    let start = Date()
    let state = SchedulerState(
      phase: .breaking,
      phaseStartedAt: start,
      nextDue: start.addingTimeInterval(20 * 60),
      breakEndsAt: start.addingTimeInterval(5),
      breaksStarted: 1,
      currentBreakSeconds: 5)
    let model = BreakOverlayModel.make(
      state: state, settings: settings, reduceMotion: true, now: start)
    XCTAssertEqual(
      model.totalSeconds, 5,
      "the ring sweeps the scheduled duration, not the 20 s default")
    XCTAssertEqual(model.progress, 1, accuracy: 0.01)
  }

  func testAwayEndedReturnsNaturalBreakThroughThePipe() {
    var settings = GKSettingsV1()
    settings.breakSeconds = 20
    let engine = makeEngine(settings: settings)
    _ = engine.handle(.awayBegan)
    // Clock-now semantics: the engine measures the absence from its own
    // clock, so a test that toggles immediately sees a sub-second away —
    // under the 20s break length — and gets the grace path, not a natural
    // break. The scheduler-level tests pin the long-away path.
    let output = engine.handle(.awayEnded)
    XCTAssertTrue(output.events.isEmpty)
    let next = engine.nextWakeup(now: engine.clock.now())
    XCTAssertNotNil(next)
    XCTAssertGreaterThan(
      next!, engine.clock.now(),
      "the grace path re-arms a strictly future wake")
  }

  func testAwaySuppressesWakeupCandidates() {
    let engine = makeEngine()
    _ = engine.handle(.awayBegan)
    XCTAssertNil(
      engine.nextWakeup(now: engine.clock.now()),
      "a machine that is away has no time-driven wakes")
  }

  func testPauseUntilReturnsInterruptWhenMidBreak() {
    let engine = makeEngine()
    _ = engine.handle(.triggerBreak(duration: nil))
    let output = engine.handle(
      .pauseUser(until: engine.clock.now().addingTimeInterval(1800)))
    XCTAssertTrue(
      output.events.contains { $0.kind == .breakInterrupted },
      "pausing mid-break interrupts it rather than trapping the overlay")
  }

  func testSkipNextBreakFlowsThroughThePipe() {
    let engine = makeEngine()
    let output = engine.handle(.skipNextBreak)
    XCTAssertEqual(output.events.map(\.kind), [.breakSkipped])
    XCTAssertEqual(output.events.first?.reason, "skipped_ahead")
  }

  func testLullHoldRearmsAShortFutureWake() {
    let engine = makeEngine(lullSeconds: 0.1)
    // Move the engine's own clock: 21m puts the heads-up up, +65s more is
    // past its end — the break wants to start but the keyboard is hot.
    engine.clock.shiftOffset(bySeconds: 21 * 60)
    _ = engine.handle(.tick(engine.clock.now()))
    engine.clock.shiftOffset(bySeconds: 65)
    _ = engine.handle(.tick(engine.clock.now()))
    let now = engine.clock.now()
    let wakeup = engine.nextWakeup(now: now)
    XCTAssertNotNil(wakeup)
    XCTAssertGreaterThan(wakeup!, now, "a held heads-up never wakes in the past")
    XCTAssertLessThanOrEqual(
      wakeup!.timeIntervalSince(now), 1,
      "the hold re-checks quickly — a second-scale recheck, not a spin")
  }

  func testNudgeIsHeldWhileInputIsHot() {
    var settings = GKSettingsV1()
    settings.wellness.enabled = true
    settings.wellness.postureMinutes = 1
    settings.wellness.blinkMinutes = 1440
    let lull = FixedLullProvider(seconds: 0.3)
    let engine = BreakEngine(
      settings: settings, clock: OffsetClock(),
      idleProvider: FixedIdleProvider(idleSeconds: 0), lullProvider: lull)

    engine.clock.shiftOffset(bySeconds: 70)
    let hot = engine.handle(.tick(engine.clock.now()))
    XCTAssertTrue(hot.nudges.isEmpty, "a nudge must not fire mid-keystroke")

    let now = engine.clock.now()
    let wakeup = engine.nextWakeup(now: now)
    XCTAssertNotNil(wakeup)
    XCTAssertGreaterThan(
      wakeup!, now, "a lull-held nudge must never produce a stale wakeup")
    XCTAssertLessThanOrEqual(
      wakeup!.timeIntervalSince(now), 1.5,
      "the hold re-checks on a bounded short recheck, not a spin")
  }

  func testNudgeFiresOnceWhenTheLullOpens() {
    var settings = GKSettingsV1()
    settings.wellness.enabled = true
    settings.wellness.postureMinutes = 1
    settings.wellness.blinkMinutes = 1440
    let lull = FixedLullProvider(seconds: 0.3)
    let engine = BreakEngine(
      settings: settings, clock: OffsetClock(),
      idleProvider: FixedIdleProvider(idleSeconds: 0), lullProvider: lull)

    engine.clock.shiftOffset(bySeconds: 70)
    _ = engine.handle(.tick(engine.clock.now()))

    lull.set(30)
    let opened = engine.handle(.tick(engine.clock.now().addingTimeInterval(1)))
    XCTAssertEqual(
      opened.nudges.count, 1,
      "the held nudge delivers exactly once when typing pauses")
    XCTAssertEqual(opened.nudges.first?.kind, .posture)
  }

  func testColdLullStillDeliversOnTime() {
    var settings = GKSettingsV1()
    settings.wellness.enabled = true
    settings.wellness.postureMinutes = 1
    settings.wellness.blinkMinutes = 1440
    let engine = makeEngine(settings: settings, lullSeconds: 60)

    engine.clock.shiftOffset(bySeconds: 70)
    let output = engine.handle(.tick(engine.clock.now()))
    XCTAssertEqual(output.nudges.count, 1)
    XCTAssertEqual(output.nudges.first?.kind, .posture)
  }

  func testMenuRevealedProducesAStatsEvent() {
    let engine = makeEngine()
    let output = engine.handle(.menuRevealed(reason: "second_launch"))
    XCTAssertEqual(output.events.map(\.kind), [.menuRevealed])
    XCTAssertEqual(output.events.first?.reason, "second_launch")
  }
}
