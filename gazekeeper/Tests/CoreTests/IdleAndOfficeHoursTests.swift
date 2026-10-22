import XCTest

@testable import GazeKeeperCore

final class MutableIdleProbe: GKIdleProviding, @unchecked Sendable {
  let seconds = LockedIdleValue()

  func currentIdleSeconds() -> TimeInterval {
    seconds.load()
  }
}

final class LockedIdleValue: @unchecked Sendable {
  private let lock = NSLock()
  private var value: TimeInterval = 42

  func load() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func store(_ newValue: TimeInterval) {
    lock.lock()
    value = newValue
    lock.unlock()
  }
}

final class IdleAndOfficeHoursTests: XCTestCase {

  private let epoch = Date(timeIntervalSince1970: 1_775_000_000)
  private let defaultHeadsUpSeconds: TimeInterval = 60

  private var due: Date { epoch.addingTimeInterval(20 * 60) }

  private func makeScheduler(
    intervalMinutes: Int = 20,
    breakSeconds: Int = 20,
    headsUpSeconds: Int = 60,
    idleSeconds: TimeInterval = 0,
    officeHours: OfficeHoursSettings? = nil
  ) -> Scheduler {
    var settings = GKSettingsV1()
    settings.intervalMinutes = intervalMinutes
    settings.breakSeconds = breakSeconds
    settings.headsUpSeconds = headsUpSeconds
    settings.naturalBreakIdleMinutes = 120
    if let officeHours {
      settings.officeHours = officeHours
    }
    return Scheduler(
      settings: settings, now: epoch,
      idleProvider: FixedIdleProvider(idleSeconds: idleSeconds))
  }

  private func officeHours(
    enabled: Bool,
    startMinute: Int,
    endMinute: Int,
    days: Set<Int>? = nil
  ) -> OfficeHoursSettings {
    var hours = OfficeHoursSettings()
    hours.enabled = enabled
    hours.startMinuteOfDay = startMinute
    hours.endMinuteOfDay = endMinute
    if let days {
      hours.days = days
    }
    return hours
  }

  private func makeProbedScheduler(
    intervalMinutes: Int = 20,
    breakSeconds: Int = 20,
    headsUpSeconds: Int = 60,
    officeHours: OfficeHoursSettings? = nil
  ) -> (Scheduler, MutableIdleProbe) {
    var settings = GKSettingsV1()
    settings.intervalMinutes = intervalMinutes
    settings.breakSeconds = breakSeconds
    settings.headsUpSeconds = headsUpSeconds
    settings.naturalBreakIdleMinutes = 120
    if let officeHours {
      settings.officeHours = officeHours
    }
    let probe = MutableIdleProbe()
    return (
      Scheduler(settings: settings, now: epoch, idleProvider: probe),
      probe
    )
  }

  private func calendarDate(
    year: Int, month: Int, day: Int, hour: Int, minute: Int
  ) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return Calendar(identifier: .gregorian).date(from: components)!
  }

  func testIdleAtOrBeyondDueAutoPostponesAndReportsEvent() {
    let scheduler = makeScheduler(idleSeconds: 300)
    let events = scheduler.tick(due)
    XCTAssertEqual(scheduler.currentState().phase, .idle)
    XCTAssertEqual(
      scheduler.currentState().nextDue.timeIntervalSince(due), 20 * 60, accuracy: 0.001)
    XCTAssertTrue(scheduler.currentState().lastPostponeReason == "idle")
    XCTAssertEqual(events.count, 1, "the postpone must reach the persistent stats log")
    XCTAssertEqual(events.first?.kind, .breakPostponed)
    XCTAssertEqual(events.first?.reason, "idle")
    let snapshot = scheduler.snapshot(at: due).events
    XCTAssertEqual(snapshot.filter { $0.kind == .breakStarted }.count, 0)
    XCTAssertEqual(snapshot.filter { $0.kind == .breakDue }.count, 0)
    XCTAssertEqual(snapshot.filter { $0.kind == .breakPostponed }.count, 1)
  }

  func testIdleBelowThresholdLetsBreakProceed() {
    let scheduler = makeScheduler(idleSeconds: 299.9)
    let events = scheduler.tick(due)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)
    XCTAssertTrue(events.contains { $0.kind == .breakDue })
  }

  func testIdleDuringHeadsUpSuppressesPendingBreakAndReturnsToIdle() {
    let (scheduler, probe) = makeProbedScheduler()
    _ = scheduler.tick(due)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)

    probe.seconds.store(300)
    let pendingBreakMoment = due.addingTimeInterval(defaultHeadsUpSeconds)
    let events = scheduler.tick(pendingBreakMoment)
    XCTAssertEqual(scheduler.currentState().phase, .idle)
    XCTAssertEqual(events.count, 1, "the postpone must reach the persistent stats log")
    XCTAssertEqual(events.first?.kind, .breakPostponed)
    XCTAssertEqual(events.first?.reason, "idle")
    XCTAssertNil(scheduler.currentState().breakEndsAt)
    XCTAssertEqual(
      scheduler.snapshot(at: pendingBreakMoment).events.filter { $0.kind == .breakStarted }
        .count, 0)

    let afterReschedule = pendingBreakMoment.addingTimeInterval(20 * 60 + 1)
    _ = scheduler.tick(afterReschedule)
    XCTAssertEqual(scheduler.currentState().phase, .idle)
  }

  func testActivityReturnAfterIdlePostponeFiresExactlyOneHeadsUp() {
    let (scheduler, probe) = makeProbedScheduler(intervalMinutes: 5)
    let firstDue = epoch.addingTimeInterval(5 * 60)
    _ = scheduler.tick(firstDue)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)

    probe.seconds.store(300)
    _ = scheduler.tick(firstDue.addingTimeInterval(defaultHeadsUpSeconds))
    XCTAssertEqual(scheduler.currentState().phase, .idle)
    XCTAssertEqual(
      scheduler.currentState().nextDue,
      firstDue.addingTimeInterval(defaultHeadsUpSeconds + 5 * 60))

    probe.seconds.store(0)
    let activeSecondCycle = scheduler.currentState().nextDue.addingTimeInterval(1)
    _ = scheduler.tick(activeSecondCycle)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)
    let headsUps = scheduler.snapshot(at: activeSecondCycle).events.filter {
      $0.kind == .breakDue
    }
    XCTAssertEqual(headsUps.count, 2)
    XCTAssertEqual(
      scheduler.snapshot(at: activeSecondCycle).events.filter { $0.kind == .breakStarted }.count,
      0)
  }

  func testQuickReturnWithinOneMinuteDoesNotDoubleFire() {
    let (scheduler, probe) = makeProbedScheduler(intervalMinutes: 5)
    let firstDue = epoch.addingTimeInterval(5 * 60)
    _ = scheduler.tick(firstDue)
    probe.seconds.store(300)
    _ = scheduler.tick(firstDue.addingTimeInterval(defaultHeadsUpSeconds))
    let rescheduledDue = scheduler.currentState().nextDue

    probe.seconds.store(0)
    let quickReturn = rescheduledDue.addingTimeInterval(10)
    _ = scheduler.tick(quickReturn)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)
    let headsUps = scheduler.snapshot(at: quickReturn).events.filter {
      $0.kind == .breakDue
    }
    XCTAssertEqual(headsUps.count, 2)

    let secondReturn = quickReturn.addingTimeInterval(30)
    _ = scheduler.tick(secondReturn)
    let totalHeadsUps = scheduler.snapshot(at: secondReturn).events.filter {
      $0.kind == .breakDue
    }
    XCTAssertEqual(totalHeadsUps.count, 2)
  }

  func testIdleProviderProtocolIsInjectableAndOverridable() {
    let probe = MutableIdleProbe()
    let settings = GKSettingsV1()
    let scheduler = Scheduler(settings: settings, now: epoch, idleProvider: probe)
    probe.seconds.store(500)
    XCTAssertEqual(scheduler.currentIdleSeconds(), 500)
    let overridden = Scheduler(
      settings: settings, now: epoch, idleProvider: probe, overrideIdleSeconds: 7)
    XCTAssertEqual(overridden.currentIdleSeconds(), 7)
  }

  func testSystemIdleProviderDefaultsToZeroWithoutInjection() {
    var settings = GKSettingsV1()
    settings.intervalMinutes = 5
    let scheduler = Scheduler(settings: settings, now: epoch)
    XCTAssertEqual(scheduler.currentIdleSeconds(), 0)
  }

  func testOfficeHoursCustomDaysOutsideSetAreSuppressed() {
    let wednesdayOnly = officeHours(
      enabled: true, startMinute: 9 * 60, endMinute: 17 * 60,
      days: [4])
    let saturdayMorning = calendarDate(year: 2026, month: 8, day: 22, hour: 10, minute: 0)
    let scheduler = makeScheduler(officeHours: wednesdayOnly)
    _ = scheduler.tick(saturdayMorning)
    XCTAssertEqual(scheduler.currentState().phase, .idle)
    XCTAssertTrue(scheduler.currentState().nextDue > saturdayMorning)
    XCTAssertTrue(
      scheduler.snapshot(at: saturdayMorning).events.filter { $0.kind == .breakDue }
        .isEmpty)
  }

  func testOfficeHoursClosedPostponeCarriesOfficeHoursReason() {
    let nineToFive = officeHours(enabled: true, startMinute: 9 * 60, endMinute: 17 * 60)
    let saturdayMorning = calendarDate(year: 2026, month: 8, day: 22, hour: 10, minute: 0)
    let scheduler = makeScheduler(officeHours: nineToFive)
    let events = scheduler.tick(saturdayMorning)
    XCTAssertEqual(scheduler.currentState().phase, .idle)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.kind, .breakPostponed)
    XCTAssertEqual(
      events.first?.reason, "office_hours",
      "closing for the schedule is not the same as the user being away")
    XCTAssertEqual(scheduler.currentState().lastPostponeReason, "office_hours")
  }

  func testOfficeHoursClosingDuringHeadsUpPostponesWithOfficeHoursReason() {
    let nineToFive = officeHours(enabled: true, startMinute: 9 * 60, endMinute: 17 * 60)
    let scheduler = makeScheduler(officeHours: nineToFive)
    let lateAfternoon = calendarDate(year: 2026, month: 8, day: 17, hour: 16, minute: 57)
    let headsUpEvents = scheduler.tick(lateAfternoon)
    XCTAssertTrue(headsUpEvents.contains { $0.kind == .breakDue })
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)

    let afterClose = calendarDate(year: 2026, month: 8, day: 17, hour: 17, minute: 1)
    let events = scheduler.tick(afterClose)
    XCTAssertEqual(scheduler.currentState().phase, .idle)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.kind, .breakPostponed)
    XCTAssertEqual(events.first?.reason, "office_hours")
  }

  func testOfficeHoursCustomDaysInsideSetFireNormally() {
    let saturdayOnly = officeHours(
      enabled: true, startMinute: 9 * 60, endMinute: 17 * 60,
      days: [7])
    let saturdayNoon = calendarDate(year: 2026, month: 8, day: 22, hour: 12, minute: 0)
    let scheduler = makeScheduler(officeHours: saturdayOnly)
    _ = scheduler.tick(saturdayNoon)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)
    XCTAssertTrue(
      scheduler.snapshot(at: saturdayNoon).events.contains { $0.kind == .breakDue })
  }

  func testOvernightWindowLateEveningIsOpen() {
    let overnight = officeHours(enabled: true, startMinute: 22 * 60, endMinute: 6 * 60)
    let mondayNight = calendarDate(year: 2026, month: 8, day: 17, hour: 23, minute: 30)
    let scheduler = makeScheduler(officeHours: overnight)
    _ = scheduler.tick(mondayNight)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)
    XCTAssertTrue(
      scheduler.snapshot(at: mondayNight).events.contains { $0.kind == .breakDue })
  }

  func testOvernightWindowEarlyMorningIsOpen() {
    let overnight = officeHours(enabled: true, startMinute: 22 * 60, endMinute: 6 * 60)
    let tuesdayDawn = calendarDate(year: 2026, month: 8, day: 18, hour: 5, minute: 59)
    let scheduler = makeScheduler(officeHours: overnight)
    _ = scheduler.tick(tuesdayDawn)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)
  }

  func testOvernightWindowDaytimeIsClosed() {
    let overnight = officeHours(enabled: true, startMinute: 22 * 60, endMinute: 6 * 60)
    let mondayMidday = calendarDate(year: 2026, month: 8, day: 17, hour: 12, minute: 0)
    let scheduler = makeScheduler(officeHours: overnight)
    _ = scheduler.tick(mondayMidday)
    XCTAssertEqual(scheduler.currentState().phase, .idle)
    XCTAssertTrue(scheduler.currentState().nextDue > mondayMidday)
  }

  func testOvernightWindowBoundaryStartMinuteIsOpenEndMinuteIsClosed() {
    let overnight = officeHours(enabled: true, startMinute: 22 * 60, endMinute: 6 * 60)
    let atStart = calendarDate(year: 2026, month: 8, day: 17, hour: 22, minute: 0)
    let openScheduler = makeScheduler(officeHours: overnight)
    _ = openScheduler.tick(atStart)
    XCTAssertEqual(openScheduler.currentState().phase, .headsUp)

    let atEnd = calendarDate(year: 2026, month: 8, day: 18, hour: 6, minute: 0)
    let closedScheduler = makeScheduler(officeHours: overnight)
    _ = closedScheduler.tick(atEnd)
    XCTAssertEqual(closedScheduler.currentState().phase, .idle)
  }

  func testDisabledOfficeHoursIgnoresWindowEntirely() {
    let disabled = officeHours(enabled: false, startMinute: 22 * 60, endMinute: 6 * 60)
    let sundayMidnight = calendarDate(year: 2026, month: 8, day: 23, hour: 3, minute: 0)
    let scheduler = makeScheduler(officeHours: disabled)
    _ = scheduler.tick(sundayMidnight)
    XCTAssertEqual(scheduler.currentState().phase, .headsUp)
  }
}
