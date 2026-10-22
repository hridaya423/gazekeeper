import XCTest

@testable import GazeKeeperCore

final class SchedulerTests: XCTestCase {

  private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  private let defaultHeadsUpSeconds: TimeInterval = 60
  private let maxPostponeSeconds: TimeInterval = 24 * 3600

  private var due: Date { epoch.addingTimeInterval(20 * 60) }

  private func makeScheduler(
    intervalMinutes: Int = 20,
    breakSeconds: Int = 20,
    headsUpSeconds: Int = 60,
    cooldownSeconds: Int = 30,
    naturalBreakIdleMinutes: Int = 1,
    officeHours: OfficeHoursSettings? = nil,
    idleSeconds: TimeInterval = 0,
    lullSeconds: TimeInterval = 60
  ) -> Scheduler {
    var settings = GKSettingsV1()
    settings.intervalMinutes = intervalMinutes
    settings.breakSeconds = breakSeconds
    settings.headsUpSeconds = headsUpSeconds
    settings.cooldownSeconds = cooldownSeconds
    settings.naturalBreakIdleMinutes = naturalBreakIdleMinutes
    if let officeHours {
      settings.officeHours = officeHours
    }
    return Scheduler(
      settings: settings, now: epoch,
      idleProvider: FixedIdleProvider(idleSeconds: idleSeconds),
      lullProvider: FixedLullProvider(seconds: lullSeconds))
  }

  func testInitialPhaseIsIdleWithNextDueOneIntervalOut() {
    let scheduler = makeScheduler(intervalMinutes: 20)
    let snapshot = scheduler.snapshot(at: epoch)
    XCTAssertEqual(snapshot.state.phase, .idle)
    XCTAssertEqual(snapshot.state.nextDue, epoch.addingTimeInterval(20 * 60))
  }

  func testFastForwardPastDueEntersBreakingThroughHeadsUp() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(epoch.addingTimeInterval(19 * 60))
    XCTAssertEqual(scheduler.snapshot(at: epoch.addingTimeInterval(19 * 60)).state.phase, .idle)

    let events = scheduler.tick(due)
    XCTAssertEqual(scheduler.snapshot(at: due).state.phase, .headsUp)
    XCTAssertTrue(events.contains { $0.kind == .breakDue })

    let breakingAt = due.addingTimeInterval(defaultHeadsUpSeconds)
    let breakEvents = scheduler.tick(breakingAt)
    XCTAssertEqual(scheduler.snapshot(at: breakingAt).state.phase, .breaking)
    XCTAssertTrue(breakEvents.contains { $0.kind == .breakStarted })
  }

  func testBreakStartsWhenHeadsUpElapses() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(due)

    let breakingAt = due.addingTimeInterval(60)
    let events = scheduler.tick(breakingAt)
    XCTAssertEqual(scheduler.snapshot(at: breakingAt).state.phase, .breaking)
    XCTAssertTrue(events.contains { $0.kind == .breakStarted })

    let snapshot = scheduler.snapshot(at: breakingAt)
    XCTAssertEqual(
      snapshot.state.breakEndsAt?.timeIntervalSince(breakingAt) ?? -1, 20, accuracy: 0.001)
  }

  func testBreakCompletesNaturallyIntoCooldown() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(due)
    let breakingAt = due.addingTimeInterval(60)
    _ = scheduler.tick(breakingAt)

    let end = breakingAt.addingTimeInterval(20)
    let events = scheduler.tick(end)
    XCTAssertEqual(scheduler.snapshot(at: end).state.phase, .cooldown)
    XCTAssertTrue(events.contains { $0.kind == .breakTaken })
    XCTAssertEqual(scheduler.snapshot(at: end).state.nextDue, end.addingTimeInterval(20 * 60))
  }

  func testInputDuringBreakLogsWorkedNotTaken() {
    let lull = FixedLullProvider(seconds: 30)
    var settings = GKSettingsV1()
    settings.intervalMinutes = 20
    settings.breakSeconds = 20
    settings.headsUpSeconds = 60
    settings.cooldownSeconds = 30
    let scheduler = Scheduler(
      settings: settings, now: epoch,
      idleProvider: FixedIdleProvider(idleSeconds: 0), lullProvider: lull)

    _ = scheduler.tick(due)
    let breakingAt = due.addingTimeInterval(60)
    _ = scheduler.tick(breakingAt)
    XCTAssertEqual(scheduler.snapshot(at: breakingAt).state.phase, .breaking)

    // A keystroke lands mid-break — the overlay still finishes, but the
    // log records what actually happened.
    lull.set(5)
    let end = breakingAt.addingTimeInterval(20)
    let events = scheduler.tick(end)
    XCTAssertEqual(events.map(\.kind), [.breakWorked])
    XCTAssertFalse(events.contains { $0.kind == .breakTaken })
    XCTAssertEqual(scheduler.snapshot(at: end).state.phase, .cooldown)
  }

  func testQuietBreakStillLogsTaken() {
    let lull = FixedLullProvider(seconds: 30)
    var settings = GKSettingsV1()
    settings.intervalMinutes = 20
    settings.breakSeconds = 20
    settings.headsUpSeconds = 60
    settings.cooldownSeconds = 30
    let scheduler = Scheduler(
      settings: settings, now: epoch,
      idleProvider: FixedIdleProvider(idleSeconds: 0), lullProvider: lull)

    _ = scheduler.tick(due)
    let breakingAt = due.addingTimeInterval(60)
    _ = scheduler.tick(breakingAt)

    let end = breakingAt.addingTimeInterval(20)
    let events = scheduler.tick(end)
    XCTAssertEqual(events.map(\.kind), [.breakTaken])
  }

  private func makeCalendarAwareScheduler() -> Scheduler {
    var settings = GKSettingsV1()
    settings.intervalMinutes = 20
    settings.calendarAware = true
    return Scheduler(
      settings: settings, now: epoch,
      idleProvider: FixedIdleProvider(idleSeconds: 0),
      lullProvider: FixedLullProvider(seconds: 60))
  }

  func testDueInLastTwoMinutesBeforeMeetingPullsForward() {
    let scheduler = makeCalendarAwareScheduler()
    // Meeting starts 90s after the pending due lands (due = epoch+1200).
    scheduler.updateMeetingStarts([epoch.addingTimeInterval(1290)], at: epoch)
    XCTAssertEqual(
      scheduler.snapshot(at: epoch).state.nextDue, epoch.addingTimeInterval(1110),
      "a due inside the last two minutes is offered three minutes out")
  }

  func testDueOutsideTwoMinuteWindowIsUntouched() {
    let scheduler = makeCalendarAwareScheduler()
    scheduler.updateMeetingStarts([epoch.addingTimeInterval(1440)], at: epoch)
    XCTAssertEqual(
      scheduler.snapshot(at: epoch).state.nextDue, epoch.addingTimeInterval(1200))
  }

  func testMeetingInThePastDoesNotAdjust() {
    let scheduler = makeCalendarAwareScheduler()
    scheduler.updateMeetingStarts([epoch.addingTimeInterval(-300)], at: epoch)
    XCTAssertEqual(
      scheduler.snapshot(at: epoch).state.nextDue, epoch.addingTimeInterval(1200))
  }

  func testCalendarDisabledLeavesDueAlone() {
    var settings = GKSettingsV1()
    settings.intervalMinutes = 20
    settings.calendarAware = false
    let scheduler = Scheduler(
      settings: settings, now: epoch,
      idleProvider: FixedIdleProvider(idleSeconds: 0),
      lullProvider: FixedLullProvider(seconds: 60))
    scheduler.updateMeetingStarts([epoch.addingTimeInterval(1290)], at: epoch)
    XCTAssertEqual(
      scheduler.snapshot(at: epoch).state.nextDue, epoch.addingTimeInterval(1200))
  }

  func testMeetingUpdateDoesNotReachIntoBreakingPhase() {
    let scheduler = makeCalendarAwareScheduler()
    _ = scheduler.tick(due)
    _ = scheduler.tick(due.addingTimeInterval(60))
    XCTAssertEqual(scheduler.snapshot(at: due).state.phase, .breaking)
    let before = scheduler.snapshot(at: due).state.nextDue
    scheduler.updateMeetingStarts(
      [due.addingTimeInterval(1290)], at: due.addingTimeInterval(60))
    XCTAssertEqual(scheduler.snapshot(at: due).state.nextDue, before)
  }

  func testAdjustIsIdempotentAcrossRepeatedUpdates() {
    let scheduler = makeCalendarAwareScheduler()
    let starts = [epoch.addingTimeInterval(1290)]
    scheduler.updateMeetingStarts(starts, at: epoch)
    scheduler.updateMeetingStarts(starts, at: epoch)
    XCTAssertEqual(
      scheduler.snapshot(at: epoch).state.nextDue, epoch.addingTimeInterval(1110),
      "a pulled-forward due must not keep sliding on re-evaluation")
  }

  func testFocusPauseHoldsIndependentlyOfUserPause() {
    let scheduler = makeScheduler()
    _ = scheduler.setPaused(byFocus: true, at: epoch)
    XCTAssertTrue(scheduler.snapshot(at: epoch).state.isPaused())
    // The user's manual pause lifting must not release the focus hold.
    _ = scheduler.setPaused(byUser: true, at: epoch)
    _ = scheduler.setPaused(byUser: false, at: epoch)
    XCTAssertTrue(
      scheduler.snapshot(at: epoch).state.isPaused(),
      "user pause cycling must leave the focus pause alone")
    _ = scheduler.setPaused(byFocus: false, at: epoch)
    XCTAssertFalse(scheduler.snapshot(at: epoch).state.isPaused())
  }

  func testFocusPauseInterruptsALiveBreak() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(due)
    _ = scheduler.tick(due.addingTimeInterval(60))
    XCTAssertEqual(scheduler.snapshot(at: due).state.phase, .breaking)
    let events = scheduler.setPaused(byFocus: true, at: due.addingTimeInterval(65))
    XCTAssertTrue(events.contains { $0.kind == .breakInterrupted && $0.reason == "focus" })
  }

  func testFocusPauseBlocksTriggerBreak() {
    let scheduler = makeScheduler()
    _ = scheduler.setPaused(byFocus: true, at: epoch)
    XCTAssertTrue(
      scheduler.triggerBreak(at: epoch).isEmpty,
      "a Focus pause must block a shortcut-driven break start")
  }

  func testBreaksStartedCountsEachBreak() {
    let scheduler = makeScheduler()
    XCTAssertEqual(scheduler.snapshot(at: epoch).state.breaksStarted, 0)

    _ = scheduler.tick(due)
    _ = scheduler.tick(due.addingTimeInterval(60))
    XCTAssertEqual(scheduler.snapshot(at: due).state.breaksStarted, 1)

    let breakEnd = due.addingTimeInterval(80)
    _ = scheduler.tick(breakEnd)
    let cooldownEnd = breakEnd.addingTimeInterval(30)
    _ = scheduler.tick(cooldownEnd)

    let secondDue = scheduler.snapshot(at: cooldownEnd).state.nextDue
    _ = scheduler.tick(secondDue)
    _ = scheduler.tick(secondDue.addingTimeInterval(60))
    XCTAssertEqual(scheduler.snapshot(at: secondDue).state.breaksStarted, 2)
  }

  func testNextTransitionTracksEachPhaseBoundary() {
    let scheduler = makeScheduler()
    XCTAssertEqual(
      scheduler.nextTransition(after: epoch),
      epoch.addingTimeInterval(20 * 60), "idle wakes at nextDue")

    _ = scheduler.tick(due)
    XCTAssertEqual(
      scheduler.nextTransition(after: due),
      due.addingTimeInterval(60), "heads-up wakes when the heads-up ends")

    let breakingAt = due.addingTimeInterval(60)
    _ = scheduler.tick(breakingAt)
    XCTAssertEqual(
      scheduler.nextTransition(after: breakingAt),
      breakingAt.addingTimeInterval(20), "breaking wakes at break end")

    let breakEnd = breakingAt.addingTimeInterval(20)
    _ = scheduler.tick(breakEnd)
    XCTAssertEqual(
      scheduler.nextTransition(after: breakEnd),
      breakEnd.addingTimeInterval(30), "cooldown wakes when it expires")
  }

  func testNextTransitionIsNilWhilePaused() {
    let scheduler = makeScheduler()
    _ = scheduler.setPaused(byUser: true, byDetector: nil, at: epoch)
    XCTAssertNil(scheduler.nextTransition(after: epoch))
  }

  func testBreaksStartedSeedsFromPriorCount() {
    var settings = GKSettingsV1()
    settings.intervalMinutes = 20
    let scheduler = Scheduler(
      settings: settings, now: epoch, idleProvider: ZeroIdleProvider(),
      priorBreaksStarted: 7)
    _ = scheduler.tick(due)
    _ = scheduler.tick(due.addingTimeInterval(60))
    XCTAssertEqual(scheduler.snapshot(at: due).state.breaksStarted, 8)
  }

  func testCooldownExpiresAfterConfiguredSecondsBackToIdle() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(due)
    _ = scheduler.tick(due.addingTimeInterval(60))
    let breakEnd = due.addingTimeInterval(80)
    _ = scheduler.tick(breakEnd)
    XCTAssertEqual(scheduler.snapshot(at: breakEnd).state.phase, .cooldown)

    let almostDone = breakEnd.addingTimeInterval(29)
    _ = scheduler.tick(almostDone)
    XCTAssertEqual(scheduler.snapshot(at: almostDone).state.phase, .cooldown)

    let idleAgain = breakEnd.addingTimeInterval(30)
    _ = scheduler.tick(idleAgain)
    let snapshot = scheduler.snapshot(at: idleAgain)
    XCTAssertEqual(snapshot.state.phase, .idle)
    XCTAssertEqual(snapshot.state.nextDue, breakEnd.addingTimeInterval(20 * 60))

    let nextDue = breakEnd.addingTimeInterval(20 * 60)
    _ = scheduler.tick(nextDue)
    XCTAssertEqual(scheduler.snapshot(at: nextDue).state.phase, .headsUp)
    XCTAssertEqual(
      scheduler.snapshot(at: nextDue).events.filter { $0.kind == .breakDue }.count, 2)
  }

  func testTriggerBreakStartsImmediateBreak() {
    let scheduler = makeScheduler()
    let events = scheduler.triggerBreak(at: epoch.addingTimeInterval(5))
    XCTAssertTrue(events.contains { $0.kind == .breakStarted })
    XCTAssertEqual(scheduler.snapshot(at: epoch.addingTimeInterval(5)).state.phase, .breaking)
  }

  func testSkipDuringBreakEndsWithSkipEvent() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)
    let skipAt = epoch.addingTimeInterval(7)
    let skipEvent = scheduler.skip(at: skipAt)
    XCTAssertNotNil(skipEvent)
    XCTAssertEqual(skipEvent?.kind, .breakSkipped)
    let snapshot = scheduler.snapshot(at: skipAt)
    XCTAssertEqual(snapshot.state.phase, .cooldown)
    XCTAssertEqual(snapshot.state.nextDue, skipAt.addingTimeInterval(20 * 60))
  }

  func testSkipOutsideBreakIsIgnored() {
    let scheduler = makeScheduler()
    XCTAssertNil(scheduler.skip(at: epoch))
  }

  func testTriggerBreakRecordsTheScheduledLength() {
    let trial = makeScheduler(breakSeconds: 20)
    _ = trial.triggerBreak(at: epoch, duration: 5)
    XCTAssertEqual(trial.snapshot(at: epoch).state.currentBreakSeconds, 5)

    let regular = makeScheduler(breakSeconds: 20)
    _ = regular.triggerBreak(at: epoch)
    XCTAssertEqual(regular.snapshot(at: epoch).state.currentBreakSeconds, 20)
  }

  func testSkipCarriesReasonOnEvent() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)
    let skipEvent = scheduler.skip(at: epoch.addingTimeInterval(3), reason: "esc")
    XCTAssertEqual(skipEvent?.reason, "esc")
    XCTAssertTrue(
      scheduler.snapshot(at: epoch.addingTimeInterval(3)).events.contains {
        $0.kind == .breakSkipped && $0.reason == "esc"
      })
  }

  func testPostponeFromIdleDefersNextDueAndLogs() {
    let scheduler = makeScheduler()
    let event = scheduler.postpone(seconds: 300, reason: "user", at: epoch)
    XCTAssertEqual(event?.kind, .breakPostponed)
    XCTAssertEqual(event?.reason, "user")
    let snapshot = scheduler.snapshot(at: epoch)
    XCTAssertEqual(snapshot.state.nextDue, epoch.addingTimeInterval(300))
    XCTAssertEqual(snapshot.state.lastPostponeReason, "user")
  }

  func testPostponeFromHeadsUpCancelsPendingBreakAndReturnsToIdle() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(due)
    XCTAssertEqual(scheduler.snapshot(at: due).state.phase, .headsUp)

    let postponeAt = due.addingTimeInterval(10)
    let event = scheduler.postpone(seconds: 300, reason: "user", at: postponeAt)
    XCTAssertEqual(event?.kind, .breakPostponed)
    let snapshot = scheduler.snapshot(at: postponeAt)
    XCTAssertEqual(snapshot.state.phase, .idle)
    XCTAssertEqual(snapshot.state.nextDue, postponeAt.addingTimeInterval(300))
    XCTAssertNil(snapshot.state.breakEndsAt)

    let oldBreakMoment = due.addingTimeInterval(60)
    _ = scheduler.tick(oldBreakMoment)
    XCTAssertEqual(scheduler.snapshot(at: oldBreakMoment).state.phase, .idle)
    XCTAssertFalse(
      scheduler.snapshot(at: oldBreakMoment).events.contains { $0.kind == .breakStarted })

    let newDue = postponeAt.addingTimeInterval(310)
    _ = scheduler.tick(newDue)
    XCTAssertEqual(scheduler.snapshot(at: newDue).state.phase, .headsUp)
  }

  func testPostponeDuringBreakEndsBreakWithoutTakingIt() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)

    let postponeAt = epoch.addingTimeInterval(3)
    let event = scheduler.postpone(seconds: 300, reason: "user", at: postponeAt)
    XCTAssertEqual(event?.kind, .breakPostponed)
    let snapshot = scheduler.snapshot(at: postponeAt)
    XCTAssertEqual(snapshot.state.phase, .idle)
    XCTAssertEqual(snapshot.state.nextDue, postponeAt.addingTimeInterval(300))

    let pastNaturalEnd = epoch.addingTimeInterval(25)
    _ = scheduler.tick(pastNaturalEnd)
    XCTAssertFalse(
      scheduler.snapshot(at: pastNaturalEnd).events.contains { $0.kind == .breakTaken })
    XCTAssertEqual(scheduler.snapshot(at: pastNaturalEnd).state.phase, .idle)
  }

  func testPostponeDurationsOfOneFiveAndFifteenMinutes() {
    for seconds in [TimeInterval(60), 300, 900] {
      let scheduler = makeScheduler()
      _ = scheduler.triggerBreak(at: epoch)
      let postponeAt = epoch.addingTimeInterval(2)
      _ = scheduler.postpone(seconds: seconds, reason: "user", at: postponeAt)
      let snapshot = scheduler.snapshot(at: postponeAt)
      XCTAssertEqual(snapshot.state.phase, .idle)
      XCTAssertEqual(snapshot.state.nextDue, postponeAt.addingTimeInterval(seconds))
    }
  }

  func testPauseFreezesPhaseAndCountdownUnderAdvancedClock() {
    let scheduler = makeScheduler()
    let pauseAt = epoch.addingTimeInterval(5)
    scheduler.setPaused(byUser: true, byDetector: nil, at: pauseAt)

    let farFuture = epoch.addingTimeInterval(7205)
    let events = scheduler.tick(farFuture)
    XCTAssertTrue(events.isEmpty)
    let pausedState = scheduler.currentState()
    XCTAssertEqual(pausedState.phase, .idle)
    XCTAssertEqual(pausedState.nextDue, epoch.addingTimeInterval(20 * 60))
    XCTAssertEqual(
      pausedState.effectiveNextDue(from: farFuture),
      farFuture.addingTimeInterval(pauseAt.distance(to: epoch.addingTimeInterval(20 * 60))))
    XCTAssertEqual(
      pausedState.pausedRemaining ?? -1,
      pauseAt.distance(to: epoch.addingTimeInterval(20 * 60)),
      accuracy: 0.001)
    XCTAssertEqual(
      pausedState.effectiveRemaining(from: farFuture),
      pauseAt.distance(to: epoch.addingTimeInterval(20 * 60)),
      accuracy: 0.001)
    XCTAssertTrue(scheduler.snapshot(at: farFuture).events.isEmpty)
  }

  func testResumeShiftsScheduleOnceForSingleCatchUp() {
    let scheduler = makeScheduler()
    let pauseAt = epoch.addingTimeInterval(5)
    scheduler.setPaused(byUser: true, byDetector: nil, at: pauseAt)

    let resumeAt = epoch.addingTimeInterval(7205)
    scheduler.setPaused(byUser: false, byDetector: nil, at: resumeAt)
    XCTAssertEqual(scheduler.currentState().nextDue, resumeAt.addingTimeInterval(1_195))

    let justBefore = resumeAt.addingTimeInterval(1_194)
    _ = scheduler.tick(justBefore)
    XCTAssertEqual(scheduler.snapshot(at: justBefore).state.phase, .idle)

    let catchUpTick = resumeAt.addingTimeInterval(1_195)
    _ = scheduler.tick(catchUpTick)
    let snapshot = scheduler.snapshot(at: catchUpTick)
    XCTAssertEqual(snapshot.state.phase, .headsUp)
    XCTAssertEqual(snapshot.events.filter { $0.kind == .breakDue }.count, 1)
    XCTAssertEqual(snapshot.events.filter { $0.kind == .breakStarted }.count, 0)
  }

  func testPauseFreezesAdvancement() {
    let scheduler = makeScheduler()
    scheduler.setPaused(byUser: true, byDetector: nil, at: epoch)

    let farFuture = epoch.addingTimeInterval(10 * 24 * 3600)
    _ = scheduler.tick(farFuture)
    let snapshot = scheduler.snapshot(at: farFuture)
    XCTAssertEqual(snapshot.state.phase, .idle)
    XCTAssertEqual(snapshot.events.filter { $0.kind == .breakDue }.count, 0)
  }

  func testDetectorPauseAlsoFreezes() {
    let scheduler = makeScheduler()
    scheduler.setPaused(byUser: false, byDetector: true, at: epoch)
    let later = epoch.addingTimeInterval(4 * 3600)
    _ = scheduler.tick(later)
    XCTAssertEqual(scheduler.snapshot(at: later).state.phase, .idle)
  }

  func testResumeAfterLongPauseProducesSingleCatchUpNotMissedBreaks() {
    let scheduler = makeScheduler()
    scheduler.setPaused(byUser: true, byDetector: nil, at: epoch)

    let resumeAt = epoch.addingTimeInterval(6 * 3600)
    scheduler.setPaused(byUser: false, byDetector: nil, at: resumeAt)
    _ = scheduler.tick(resumeAt.addingTimeInterval(1))

    let events = scheduler.snapshot(at: resumeAt.addingTimeInterval(1)).events
    let headsUps = events.filter { $0.kind == .breakDue }.count
    let breaks = events.filter { $0.kind == .breakStarted }.count
    XCTAssertLessThanOrEqual(headsUps, 1)
    XCTAssertLessThanOrEqual(breaks, 1)
  }

  func testSettingsUpdateRecomputesNextDueImmediatelyFromIdle() {
    let scheduler = makeScheduler(intervalMinutes: 20)
    var updated = GKSettingsV1()
    updated.intervalMinutes = 45

    let changedAt = epoch.addingTimeInterval(120)
    scheduler.updateSettings(updated, at: changedAt)
    let snapshot = scheduler.snapshot(at: changedAt)
    XCTAssertEqual(snapshot.settings.intervalMinutes, 45)
    XCTAssertEqual(snapshot.state.nextDue, changedAt.addingTimeInterval(45 * 60))
  }

  func testSettingsUpdateDuringActiveBreakPreservesBreakWindow() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)

    var updated = GKSettingsV1()
    updated.intervalMinutes = 45
    let midBreak = epoch.addingTimeInterval(10)
    scheduler.updateSettings(updated, at: midBreak)

    let snapshot = scheduler.snapshot(at: midBreak)
    XCTAssertEqual(snapshot.state.phase, .breaking)
    XCTAssertEqual(snapshot.state.breakEndsAt, epoch.addingTimeInterval(20))

    let end = epoch.addingTimeInterval(20)
    _ = scheduler.tick(end)
    let finished = scheduler.snapshot(at: end)
    XCTAssertEqual(finished.state.phase, .cooldown)
    XCTAssertEqual(finished.state.nextDue, end.addingTimeInterval(45 * 60))
  }

  func testSettingsUpdateDuringHeadsUpKeepsPendingBreakDeadline() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(due)

    var updated = GKSettingsV1()
    updated.intervalMinutes = 45
    scheduler.updateSettings(updated, at: due.addingTimeInterval(5))

    let breakingAt = due.addingTimeInterval(60)
    _ = scheduler.tick(breakingAt)
    XCTAssertEqual(scheduler.snapshot(at: breakingAt).state.phase, .breaking)
  }

  func testHeadsUpDurationMatchesSetting() {
    let scheduler = makeScheduler(headsUpSeconds: 15)
    _ = scheduler.tick(due)
    XCTAssertEqual(scheduler.snapshot(at: due.addingTimeInterval(14)).state.phase, .headsUp)

    let breakingAt = due.addingTimeInterval(15)
    _ = scheduler.tick(breakingAt)
    XCTAssertEqual(scheduler.snapshot(at: breakingAt).state.phase, .breaking)
  }

  func testEventsCarryTheirTickTimestamps() {
    let scheduler = makeScheduler()
    let headsUpEvents = scheduler.tick(due)
    XCTAssertEqual(headsUpEvents.first?.at, due)
    XCTAssertEqual(headsUpEvents.first?.kind, .breakDue)

    let breakingAt = due.addingTimeInterval(60)
    let breakEvents = scheduler.tick(breakingAt)
    XCTAssertEqual(breakEvents.first?.at, breakingAt)
    XCTAssertEqual(breakEvents.first?.kind, .breakStarted)
  }

  func testOfficeHoursSuppressOutsideWindow() {
    var officeHours = OfficeHoursSettings()
    officeHours.enabled = true
    officeHours.startMinuteOfDay = 9 * 60
    officeHours.endMinuteOfDay = 17 * 60

    let calendar = Calendar(identifier: .gregorian)
    let weekdayEvening = dateOnWeekday(hour: 20, minute: 5, calendar: calendar)
    let scheduler = makeScheduler(officeHours: officeHours)
    _ = scheduler.tick(weekdayEvening.addingTimeInterval(25 * 3600))

    XCTAssertEqual(
      scheduler.snapshot(at: weekdayEvening.addingTimeInterval(25 * 3600)).state.phase, .idle)
    XCTAssertEqual(
      scheduler.snapshot(at: weekdayEvening.addingTimeInterval(25 * 3600)).events.filter {
        $0.kind == .breakDue
      }.count, 0)
  }

  func testOvernightWindowCrossesMidnight() {
    var officeHours = OfficeHoursSettings()
    officeHours.enabled = true
    officeHours.startMinuteOfDay = 22 * 60
    officeHours.endMinuteOfDay = 6 * 60

    let calendar = Calendar(identifier: .gregorian)
    let lateNight = dateOnWeekday(hour: 23, minute: 30, calendar: calendar)
    let scheduler = makeScheduler(officeHours: officeHours)
    _ = scheduler.tick(lateNight.addingTimeInterval(20 * 60))
    _ = scheduler.tick(lateNight.addingTimeInterval(20 * 60 + 60))

    XCTAssertEqual(
      scheduler.snapshot(at: lateNight.addingTimeInterval(20 * 60 + 61)).state.phase, .breaking)
  }

  func testSnapshotAtDoesNotAdvanceOrMutateState() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(due)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)

    let farFuture = due.addingTimeInterval(10 * 3600)
    let snapshot = scheduler.snapshot(at: farFuture)
    XCTAssertEqual(snapshot.state.phase, .headsUp)
    XCTAssertEqual(snapshot.state.nextDue, epoch.addingTimeInterval(20 * 60 + 60))
    XCTAssertEqual(
      scheduler.snapshot(at: farFuture).events.filter { $0.kind == .breakStarted }.count, 0)

    XCTAssertEqual(scheduler.tick(farFuture).count, 1)
    XCTAssertEqual(scheduler.currentState().phase, .breaking)
  }

  func testRedundantPauseCallsDoNotRewindFrozenCountdown() {
    let scheduler = makeScheduler()
    scheduler.setPaused(byUser: true, byDetector: nil, at: epoch.addingTimeInterval(5))
    scheduler.setPaused(byUser: true, byDetector: nil, at: epoch.addingTimeInterval(600))
    let state = scheduler.currentState()
    XCTAssertTrue(state.pausedByUser)
    XCTAssertEqual(state.pausedRemaining ?? -1, 20 * 60 - 5, accuracy: 0.001)
  }

  func testResumeWhileRunningIsNoOp() {
    let scheduler = makeScheduler()
    scheduler.setPaused(byUser: false, byDetector: nil, at: epoch.addingTimeInterval(30))
    let state = scheduler.currentState()
    XCTAssertFalse(state.isPaused())
    XCTAssertNil(state.pausedRemaining)
    XCTAssertEqual(state.nextDue, epoch.addingTimeInterval(20 * 60))
    XCTAssertEqual(state.phaseStartedAt, epoch)
  }

  func testPauseDuringBreakInterruptsAndEntersCooldown() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)

    let pauseAt = epoch.addingTimeInterval(5)
    let events = scheduler.setPaused(byUser: true, byDetector: nil, at: pauseAt)
    XCTAssertEqual(events.map(\.kind), [.breakInterrupted])
    XCTAssertEqual(events.first?.reason, "user")

    let state = scheduler.currentState()
    XCTAssertEqual(state.phase, .cooldown)
    XCTAssertNil(state.breakEndsAt, "the overlay must come down, not freeze on screen")
    XCTAssertTrue(state.isPaused())
  }

  func testDetectorPauseDuringBreakInterruptsWithDetectorReason() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)

    let events = scheduler.setPaused(byUser: nil, byDetector: true, at: epoch)
    XCTAssertEqual(events.map(\.kind), [.breakInterrupted])
    XCTAssertEqual(events.first?.reason, "detector")
    XCTAssertEqual(scheduler.currentState().phase, .cooldown)
  }

  func testSecondPauseAfterInterruptEmitsNoDuplicateEvent() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)
    _ = scheduler.setPaused(byUser: true, byDetector: nil, at: epoch.addingTimeInterval(5))

    let events = scheduler.setPaused(
      byUser: nil, byDetector: true, at: epoch.addingTimeInterval(8))
    XCTAssertTrue(events.isEmpty)
    XCTAssertEqual(
      scheduler.snapshot(at: epoch).events.filter { $0.kind == .breakInterrupted }.count, 1)
  }

  func testPauseOutsideBreakEmitsNothing() {
    let scheduler = makeScheduler()
    let events = scheduler.setPaused(byUser: true, byDetector: nil, at: epoch)
    XCTAssertTrue(events.isEmpty)
  }

  func testResumeAfterInterruptedBreakFinishesCooldownThenIdles() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)
    _ = scheduler.setPaused(byUser: true, byDetector: nil, at: epoch.addingTimeInterval(5))

    let resumeAt = epoch.addingTimeInterval(3_600)
    _ = scheduler.setPaused(byUser: false, byDetector: nil, at: resumeAt)
    XCTAssertEqual(scheduler.currentState().phase, .cooldown)
    XCTAssertNil(scheduler.currentState().pausedRemaining)

    let cooldownEnd = resumeAt.addingTimeInterval(30)
    _ = scheduler.tick(cooldownEnd)
    XCTAssertEqual(scheduler.currentState().phase, .idle)

    let nextDueAt = scheduler.currentState().nextDue
    _ = scheduler.tick(nextDueAt)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)
  }

  func testResumeMidHeadsUpRestoresPendingBreakDeadline() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(due)

    let pauseAt = due.addingTimeInterval(10)
    scheduler.setPaused(byUser: true, byDetector: nil, at: pauseAt)

    let resumeAt = epoch.addingTimeInterval(9 * 3600)
    scheduler.setPaused(byUser: false, byDetector: nil, at: resumeAt)
    let resumed = scheduler.currentState()
    XCTAssertEqual(resumed.phase, .headsUp)
    XCTAssertEqual(resumed.nextDue, resumeAt.addingTimeInterval(50))

    _ = scheduler.tick(resumeAt.addingTimeInterval(50))
    XCTAssertEqual(scheduler.currentState().phase, .breaking)
  }

  func testPostponeClampsToUpperBound() {
    let scheduler = makeScheduler()
    let event = scheduler.postpone(seconds: 1e12, reason: "user", at: epoch)
    XCTAssertEqual(event?.kind, .breakPostponed)
    let snapshot = scheduler.currentState()
    XCTAssertEqual(snapshot.nextDue.timeIntervalSince(epoch), maxPostponeSeconds)
  }

  func testPostponeDuringBreakAnchorsNextIntervalAtPostponeMoment() {
    let scheduler = makeScheduler(intervalMinutes: 5)
    _ = scheduler.triggerBreak(at: epoch)

    let postponeAt = epoch.addingTimeInterval(8)
    _ = scheduler.postpone(seconds: 300, reason: "user", at: postponeAt)
    let snapshot = scheduler.currentState()
    XCTAssertEqual(snapshot.phase, .idle)
    XCTAssertEqual(snapshot.nextDue, postponeAt.addingTimeInterval(300))
    XCTAssertNil(snapshot.breakEndsAt)
  }

  func testSkipAnchorsNextIntervalAtSkipMoment() {
    let scheduler = makeScheduler(intervalMinutes: 5)
    _ = scheduler.triggerBreak(at: epoch)
    let skipAt = epoch.addingTimeInterval(7)
    _ = scheduler.skip(at: skipAt)
    let snapshot = scheduler.currentState()
    XCTAssertEqual(snapshot.nextDue, skipAt.addingTimeInterval(5 * 60))
    XCTAssertEqual(snapshot.breakEndsAt, nil)
  }

  func testPausedMidBreakEndsBreakInsteadOfFreezingOverlay() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)

    let pauseAt = epoch.addingTimeInterval(5)
    scheduler.setPaused(byUser: true, byDetector: nil, at: pauseAt)

    let lateProbe = epoch.addingTimeInterval(600)
    _ = scheduler.tick(lateProbe)
    XCTAssertNil(scheduler.currentState().breakEndsAt)
    XCTAssertEqual(
      scheduler.currentState().phase, .cooldown,
      "a paused break must not leave the overlay phase alive")

    scheduler.setPaused(byUser: false, byDetector: nil, at: lateProbe.addingTimeInterval(2))
    _ = scheduler.tick(lateProbe.addingTimeInterval(32))
    XCTAssertEqual(scheduler.currentState().phase, .idle)
    XCTAssertNil(scheduler.currentState().breakEndsAt)
  }

  func testSkipAfterInterruptedBreakIsANoOp() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)
    scheduler.setPaused(byUser: true, byDetector: nil, at: epoch.addingTimeInterval(5))
    XCTAssertNotNil(scheduler.currentState().pausedRemaining)
    XCTAssertEqual(scheduler.currentState().phase, .cooldown)

    let event = scheduler.skip(at: epoch.addingTimeInterval(7), reason: "user")
    XCTAssertNil(event, "there is no break left to skip after an interrupt")
    XCTAssertTrue(scheduler.currentState().isPaused())
    XCTAssertEqual(
      scheduler.currentState().pausedRemaining ?? -1, 20 * 60, accuracy: 0.001,
      "the frozen interval from the interrupted cooldown is untouched")

    scheduler.setPaused(byUser: false, byDetector: nil, at: epoch.addingTimeInterval(3_600))
    let state = scheduler.currentState()
    XCTAssertEqual(state.phase, .cooldown)
    XCTAssertEqual(state.nextDue, epoch.addingTimeInterval(3_600 + 20 * 60))
  }

  func testPostponeWhilePausedRefreezesAgainstNewAnchor() {
    let scheduler = makeScheduler(intervalMinutes: 5)
    scheduler.setPaused(byUser: true, byDetector: nil, at: epoch.addingTimeInterval(5))
    XCTAssertNotNil(scheduler.currentState().pausedRemaining)

    let postponeAt = epoch.addingTimeInterval(10)
    _ = scheduler.postpone(seconds: 300, reason: "user", at: postponeAt)
    var state = scheduler.currentState()
    XCTAssertTrue(state.pausedByUser)
    XCTAssertEqual(state.pausedRemaining ?? -1, 300, accuracy: 0.001)
    XCTAssertEqual(state.nextDue, postponeAt.addingTimeInterval(300))
    XCTAssertNil(state.breakEndsAt)

    let resumeAt = epoch.addingTimeInterval(3_600)
    scheduler.setPaused(byUser: false, byDetector: nil, at: resumeAt)
    state = scheduler.currentState()
    XCTAssertNil(state.pausedRemaining)
    XCTAssertEqual(state.nextDue, resumeAt.addingTimeInterval(300))
  }

  func testDoubleResumeAfterInterruptedBreakKeepsSchedule() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)
    scheduler.setPaused(byUser: true, byDetector: nil, at: epoch.addingTimeInterval(5))

    let resumeAt = epoch.addingTimeInterval(3_600)
    scheduler.setPaused(byUser: false, byDetector: nil, at: resumeAt)
    scheduler.setPaused(byUser: false, byDetector: nil, at: resumeAt.addingTimeInterval(60))

    let state = scheduler.currentState()
    XCTAssertNil(state.breakEndsAt)
    XCTAssertEqual(state.nextDue, resumeAt.addingTimeInterval(20 * 60))
  }

  private func dateOnWeekday(hour: Int, minute: Int, calendar: Calendar) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 19
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components)!
  }

  // MARK: - Task 2.1: away-aware cadence

  func testAwayLongerThanBreakResetsCadenceAsNaturalBreak() {
    let scheduler = makeScheduler(breakSeconds: 20)
    let awayAt = epoch.addingTimeInterval(5 * 60)
    scheduler.awayBegan(at: awayAt)

    let backAt = awayAt.addingTimeInterval(10 * 60)
    let events = scheduler.awayEnded(at: backAt)
    XCTAssertEqual(
      events.map(\.kind), [.naturalBreak],
      "10 minutes away with a 20-second break is a natural break")
    let state = scheduler.currentState()
    XCTAssertEqual(state.phase, .idle)
    XCTAssertFalse(state.isAway)
    XCTAssertEqual(
      state.nextDue, backAt.addingTimeInterval(20 * 60),
      "cadence resets to a full interval from the return")
  }

  func testShortAwayPushesNextDueIntoGraceWindow() {
    let scheduler = makeScheduler(breakSeconds: 20)
    let awayAt = epoch.addingTimeInterval(19 * 60 + 30)
    scheduler.awayBegan(at: awayAt)

    let backAt = awayAt.addingTimeInterval(10)
    let events = scheduler.awayEnded(at: backAt)
    XCTAssertTrue(events.isEmpty, "10 seconds away is not a natural break")
    let state = scheduler.currentState()
    XCTAssertEqual(
      state.nextDue, backAt.addingTimeInterval(60),
      "the due that landed mid-away slides to the 60-second grace edge")
  }

  func testNoTransitionWithinSixtySecondsOfWake() {
    let scheduler = makeScheduler(breakSeconds: 20)
    let awayAt = epoch.addingTimeInterval(19 * 60 + 55)
    scheduler.awayBegan(at: awayAt)
    let backAt = awayAt.addingTimeInterval(5)
    _ = scheduler.awayEnded(at: backAt)

    // 5 seconds after waking the due would have fired — grace holds it.
    let early = scheduler.tick(backAt.addingTimeInterval(5))
    XCTAssertTrue(early.isEmpty)
    XCTAssertEqual(scheduler.currentState().phase, .idle)
  }

  func testWhileAwayTickIsInert() {
    let scheduler = makeScheduler()
    scheduler.awayBegan(at: epoch)
    let events = scheduler.tick(epoch.addingTimeInterval(25 * 60))
    XCTAssertTrue(events.isEmpty, "a locked or sleeping machine emits nothing")
    XCTAssertNil(
      scheduler.nextTransition(after: epoch.addingTimeInterval(25 * 60)),
      "no time-driven transitions exist while away")
  }

  func testLongAwayDuringBreakMergesIntoNaturalBreak() {
    let scheduler = makeScheduler(breakSeconds: 20)
    _ = scheduler.tick(due)
    _ = scheduler.tick(due.addingTimeInterval(60))  // break starts

    let midBreak = due.addingTimeInterval(70)  // 10s into the break
    scheduler.awayBegan(at: midBreak)
    let backAt = midBreak.addingTimeInterval(300)  // away past breakEndsAt
    let events = scheduler.awayEnded(at: backAt)
    XCTAssertEqual(
      events.map(\.kind), [.naturalBreak],
      "an in-flight break absorbed by a longer absence is one rest, once")
    XCTAssertEqual(scheduler.currentState().phase, .idle)
  }

  func testShortAwayDuringBreakStillCompletes() {
    let scheduler = makeScheduler(breakSeconds: 20)
    _ = scheduler.tick(due)
    _ = scheduler.tick(due.addingTimeInterval(60))  // break starts

    let midBreak = due.addingTimeInterval(75)  // 15s into the break
    scheduler.awayBegan(at: midBreak)
    let backAt = midBreak.addingTimeInterval(10)  // back 5s past breakEndsAt
    let events = scheduler.awayEnded(at: backAt)
    XCTAssertTrue(events.isEmpty, "no grace applies to a running break")

    let completion = scheduler.tick(backAt.addingTimeInterval(1))
    XCTAssertTrue(
      completion.contains { $0.kind == .breakTaken },
      "the break that finished while locked counts as taken")
    XCTAssertEqual(scheduler.currentState().phase, .cooldown)
  }

  func testAwayLongerThanBreakDuringHeadsUpBecomesNaturalBreak() {
    let scheduler = makeScheduler(breakSeconds: 20)
    _ = scheduler.tick(due)  // heads-up starts

    let awayAt = due.addingTimeInterval(30)
    scheduler.awayBegan(at: awayAt)
    let events = scheduler.awayEnded(at: awayAt.addingTimeInterval(120))
    XCTAssertEqual(events.map(\.kind), [.naturalBreak])
    XCTAssertEqual(scheduler.currentState().phase, .idle)
  }

  func testIdleBeyondNaturalBreakResetsCadence() {
    let scheduler = makeScheduler(
      breakSeconds: 20, naturalBreakIdleMinutes: 1,
      idleSeconds: 90)
    let tickAt = epoch.addingTimeInterval(5 * 60)
    let events = scheduler.tick(tickAt)
    XCTAssertEqual(
      events.map(\.kind), [.naturalBreak],
      "90s idle exceeds the 1-minute natural-break threshold")
    XCTAssertEqual(
      scheduler.currentState().nextDue, tickAt.addingTimeInterval(20 * 60))
  }

  func testIdleNaturalBreakFiresOncePerIdleRunWithoutSpam() {
    let scheduler = makeScheduler(
      breakSeconds: 20, naturalBreakIdleMinutes: 1,
      idleSeconds: 300)
    let first = scheduler.tick(epoch.addingTimeInterval(5 * 60))
    XCTAssertEqual(first.map(\.kind), [.naturalBreak])

    // Still idle: the cadence parks quietly — no repeated events.
    let later = epoch.addingTimeInterval(25 * 60)
    let second = scheduler.tick(later)
    XCTAssertTrue(second.isEmpty)
    XCTAssertEqual(
      scheduler.currentState().nextDue, later.addingTimeInterval(20 * 60))
  }

  func testIdlePostponeStillAppliesBelowNaturalBreak() {
    // naturalBreak 30m > idleThreshold 300s: a 6-minute idle postpones,
    // not resets.
    let scheduler = makeScheduler(
      breakSeconds: 20, naturalBreakIdleMinutes: 30,
      idleSeconds: 360)
    let events = scheduler.tick(due)
    XCTAssertEqual(events.map(\.kind), [.breakPostponed])
    XCTAssertEqual(events.first?.reason, "idle")
  }

  // MARK: - Task 2.2: timed pause, snooze limit, skip-next

  func testTimedPauseAutoResumesAtDeadline() {
    let scheduler = makeScheduler()
    scheduler.pauseUser(until: epoch.addingTimeInterval(30 * 60), at: epoch)
    XCTAssertTrue(scheduler.currentState().pausedByUser)
    XCTAssertNil(scheduler.nextTransition(after: epoch) == nil ? nil : nil)

    _ = scheduler.tick(epoch.addingTimeInterval(29 * 60))
    XCTAssertTrue(
      scheduler.currentState().pausedByUser, "still paused before the deadline")

    _ = scheduler.tick(epoch.addingTimeInterval(31 * 60))
    XCTAssertFalse(
      scheduler.currentState().pausedByUser, "the deadline passed — pause lifts")
    XCTAssertEqual(scheduler.currentState().phase, .idle)
  }

  func testTimedPauseIsTheOnlyPausedWake() {
    let scheduler = makeScheduler()
    scheduler.pauseUser(until: epoch.addingTimeInterval(1800), at: epoch)
    XCTAssertEqual(
      scheduler.nextTransition(after: epoch), epoch.addingTimeInterval(1800),
      "a timed pause still has exactly one time-driven edge")
  }

  func testIndefinitePauseHasNoTimedEdge() {
    let scheduler = makeScheduler()
    _ = scheduler.setPaused(byUser: true, byDetector: nil, at: epoch)
    XCTAssertNil(scheduler.nextTransition(after: epoch))
  }

  func testUnpausingClearsTheDeadline() {
    let scheduler = makeScheduler()
    scheduler.pauseUser(until: epoch.addingTimeInterval(1800), at: epoch)
    _ = scheduler.setPaused(byUser: false, byDetector: nil, at: epoch.addingTimeInterval(60))
    XCTAssertNil(scheduler.currentState().pausedUntil)
    XCTAssertFalse(scheduler.currentState().pausedByUser)
  }

  func testSnoozeLimitExhaustsAfterSettingCount() {
    var settings = GKSettingsV1()
    settings.snoozeLimit = 2
    let scheduler = Scheduler(
      settings: settings, now: epoch,
      idleProvider: FixedIdleProvider(idleSeconds: 0))
    _ = scheduler.tick(due)  // heads-up: due is open

    XCTAssertNotNil(scheduler.postpone(seconds: 300, reason: "user", at: due))
    _ = scheduler.tick(due.addingTimeInterval(300))
    XCTAssertNotNil(
      scheduler.postpone(seconds: 300, reason: "user", at: due.addingTimeInterval(300)))

    _ = scheduler.tick(due.addingTimeInterval(600))
    let exhausted = scheduler.postpone(
      seconds: 300, reason: "user", at: due.addingTimeInterval(600))
    XCTAssertEqual(
      exhausted?.kind, .snoozeExhausted,
      "the third snooze of one break is refused")
    XCTAssertEqual(
      scheduler.currentState().nextDue, due.addingTimeInterval(660),
      "an exhausted snooze does not move the due")
  }

  func testSystemPostponesDoNotConsumeSnoozes() {
    var settings = GKSettingsV1()
    settings.snoozeLimit = 1
    let scheduler = Scheduler(
      settings: settings, now: epoch,
      idleProvider: FixedIdleProvider(idleSeconds: 0))
    _ = scheduler.tick(due)

    XCTAssertNotNil(scheduler.postpone(seconds: 60, reason: "idle", at: due))
    _ = scheduler.tick(due.addingTimeInterval(60))
    let user = scheduler.postpone(seconds: 60, reason: "user", at: due.addingTimeInterval(60))
    XCTAssertEqual(
      user?.kind, .breakPostponed,
      "machine postponements never consume the user's snooze budget")
  }

  func testSnoozeBudgetResetsOnTheNextDue() {
    var settings = GKSettingsV1()
    settings.snoozeLimit = 1
    let scheduler = Scheduler(
      settings: settings, now: epoch,
      idleProvider: FixedIdleProvider(idleSeconds: 0))
    _ = scheduler.tick(due)
    _ = scheduler.postpone(seconds: 60, reason: "user", at: due)

    _ = scheduler.tick(due.addingTimeInterval(60))  // heads-up again
    _ = scheduler.tick(due.addingTimeInterval(120))  // break
    _ = scheduler.tick(due.addingTimeInterval(140))  // taken → cooldown
    _ = scheduler.tick(due.addingTimeInterval(200))  // back to idle
    _ = scheduler.tick(due.addingTimeInterval(1400))  // fresh due

    let snooze = scheduler.postpone(seconds: 60, reason: "user", at: due.addingTimeInterval(1400))
    XCTAssertEqual(
      snooze?.kind, .breakPostponed,
      "a new break brings a fresh snooze budget")
  }

  func testSkipNextBreakInIdlePushesAFullInterval() {
    let scheduler = makeScheduler()
    let event = scheduler.skipNextBreak(at: epoch)
    XCTAssertEqual(event?.kind, .breakSkipped)
    XCTAssertEqual(event?.reason, "skipped_ahead")
    XCTAssertEqual(
      scheduler.currentState().nextDue, epoch.addingTimeInterval(20 * 60),
      "the upcoming break is cancelled — the cadence restarts")
    XCTAssertEqual(scheduler.currentState().phase, .idle)
  }

  func testSkipNextBreakDuringHeadsUpResolvesTheDue() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(due)
    let event = scheduler.skipNextBreak(at: due)
    XCTAssertEqual(event?.kind, .breakSkipped)
    XCTAssertEqual(
      event?.reason, "user",
      "skipping a due that already fired is a real skip, not skip-ahead")
    XCTAssertEqual(scheduler.currentState().phase, .cooldown)
  }

  func testSkipNextBreakDuringBreakIsRefused() {
    let scheduler = makeScheduler()
    _ = scheduler.tick(due)
    _ = scheduler.tick(due.addingTimeInterval(60))
    XCTAssertNil(
      scheduler.skipNextBreak(at: due.addingTimeInterval(60)),
      "a running break is skipped with skip(), not skipped ahead")
  }

  // MARK: - Task 2.3: long breaks

  private func makeLongBreakScheduler(every: Int, longSeconds: Int) -> Scheduler {
    var settings = GKSettingsV1()
    settings.intervalMinutes = 20
    settings.breakSeconds = 20
    settings.headsUpSeconds = 60
    settings.cooldownSeconds = 30
    settings.longBreakEvery = every
    settings.longBreakSeconds = longSeconds
    return Scheduler(
      settings: settings, now: epoch,
      idleProvider: FixedIdleProvider(idleSeconds: 0))
  }

  private func runBreakCycle(_ scheduler: Scheduler, startAt: Date) -> [SchedulerEvent] {
    var events: [SchedulerEvent] = []
    events.append(contentsOf: scheduler.tick(startAt))
    events.append(contentsOf: scheduler.tick(startAt.addingTimeInterval(60)))
    events.append(contentsOf: scheduler.tick(startAt.addingTimeInterval(400)))
    events.append(contentsOf: scheduler.tick(startAt.addingTimeInterval(440)))
    return events
  }

  func testEveryNthBreakIsLongWithItsOwnLength() {
    let scheduler = makeLongBreakScheduler(every: 3, longSeconds: 300)
    // Each cycle ends with nextDue = completionTick + interval.
    var cursor = epoch.addingTimeInterval(20 * 60)

    for round in 1...3 {
      let events = runBreakCycle(scheduler, startAt: cursor)
      let started = events.first { $0.kind == .breakStarted }
      XCTAssertNotNil(started)
      XCTAssertEqual(
        started?.long, round == 3,
        round == 3 ? "every 3rd break is long" : "break \(round) is short")
      cursor = cursor.addingTimeInterval(1600)
    }
  }

  func testLongBreakDurationGovernsBreakEnd() {
    let scheduler = makeLongBreakScheduler(every: 1, longSeconds: 300)
    _ = scheduler.tick(due)
    _ = scheduler.tick(due.addingTimeInterval(60))
    XCTAssertEqual(
      scheduler.currentState().breakEndsAt, due.addingTimeInterval(360),
      "a long break runs its own length")
  }

  func testLongBreakDisabledWhenEveryIsZero() {
    let scheduler = makeLongBreakScheduler(every: 0, longSeconds: 300)
    let events = runBreakCycle(scheduler, startAt: due)
    XCTAssertEqual(events.first { $0.kind == .breakStarted }?.long, false)
  }

  func testBreakDueCarriesTheLongFlagForThePill() {
    let scheduler = makeLongBreakScheduler(every: 1, longSeconds: 300)
    let events = scheduler.tick(due)
    XCTAssertEqual(
      events.first { $0.kind == .breakDue }?.long, true,
      "the heads-up knows the incoming break is long")
  }

  // MARK: - Task 2.4: typing-lull break hold

  func testBreakWaitsForATypingLull() {
    // lull 0.5s — the user is actively typing when the heads-up ends.
    let scheduler = makeScheduler(headsUpSeconds: 60, lullSeconds: 0.5)
    _ = scheduler.tick(due)
    let events = scheduler.tick(due.addingTimeInterval(60))
    XCTAssertTrue(events.isEmpty, "no break mid-keystroke")
    XCTAssertEqual(
      scheduler.currentState().phase, .headsUp,
      "the heads-up holds while input is hot")
  }

  func testBreakStartsOnceTheLullOpens() {
    let scheduler = makeScheduler(headsUpSeconds: 60, lullSeconds: 60)
    _ = scheduler.tick(due)
    let events = scheduler.tick(due.addingTimeInterval(60))
    XCTAssertTrue(
      events.contains { $0.kind == .breakStarted },
      "a quiet keyboard lets the break begin on time")
  }

  func testLullHoldCapsAtThirtySeconds() {
    // Input never stops — the break must still land inside the 30s cap.
    let scheduler = makeScheduler(headsUpSeconds: 60, lullSeconds: 0.1)
    _ = scheduler.tick(due)
    let cappedAt = due.addingTimeInterval(90)  // 60 + 30
    let events = scheduler.tick(cappedAt)
    XCTAssertTrue(
      events.contains { $0.kind == .breakStarted },
      "the 30-second cap overrides the lull")
    XCTAssertEqual(scheduler.currentState().phase, .breaking)
  }

  func testLullHoldReschedulesAShortRecheck() {
    let scheduler = makeScheduler(headsUpSeconds: 60, lullSeconds: 0.5)
    _ = scheduler.tick(due)
    _ = scheduler.tick(due.addingTimeInterval(60))
    let next = scheduler.nextTransition(after: due.addingTimeInterval(61))
    XCTAssertNotNil(next)
    XCTAssertLessThanOrEqual(
      next!.timeIntervalSince(due.addingTimeInterval(61)), 1,
      "a held heads-up re-checks quickly instead of spinning")
    XCTAssertGreaterThan(next!, due.addingTimeInterval(61))
  }
}
