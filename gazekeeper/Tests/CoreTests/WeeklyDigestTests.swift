import XCTest

@testable import GazeKeeperCore

final class WeeklyDigestTests: XCTestCase {

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
  }

  private func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    var c = DateComponents()
    c.year = y
    c.month = m
    c.day = d
    c.hour = h
    c.minute = min
    return utcCalendar.date(from: c)!
  }

  // 2026-03-30 is a Monday.
  private var mondayNoon: Date { utcDate(2026, 3, 30, 12, 0) }
  private var mondayMorning: Date { utcDate(2026, 3, 30, 9, 1) }
  private var tuesday: Date { utcDate(2026, 3, 31, 10, 0) }

  private func makeCadence(weeklyDigest: Bool, at now: Date) -> WellnessCadence {
    var settings = GKSettingsV1()
    settings.wellness.enabled = true
    settings.wellness.weeklyDigest = weeklyDigest
    // Park posture/blink a day out — the tests are about the digest kind.
    settings.wellness.postureMinutes = 1440
    settings.wellness.blinkMinutes = 1440
    return WellnessCadence(settings: settings, now: now, calendar: utcCalendar)
  }

  private func tick(
    _ cadence: WellnessCadence, at date: Date, phase: GazeKeeperPhase = .idle
  ) -> [WellnessNudge] {
    cadence.tick(
      at: date,
      context: WellnessContext(
        schedulerPhase: phase, pausedByUser: false, pausedByDetector: false))
  }

  func testNextDeliveryOnMondayBeforeNineIsSameMorning() {
    let delivery = WeeklyDigest.nextDelivery(
      from: utcDate(2026, 3, 30, 8, 30), calendar: utcCalendar)
    XCTAssertEqual(delivery, utcDate(2026, 3, 30, 9, 0))
  }

  func testNextDeliveryOnTuesdayIsNextMonday() {
    let delivery = WeeklyDigest.nextDelivery(from: tuesday, calendar: utcCalendar)
    XCTAssertEqual(delivery, utcDate(2026, 4, 6, 9, 0))
  }

  func testDigestOffByDefaultNeverFires() {
    let cadence = makeCadence(weeklyDigest: false, at: utcDate(2026, 3, 30, 7, 0))
    XCTAssertTrue(tick(cadence, at: mondayNoon).isEmpty)
  }

  func testDigestFiresOnMondayAfterNine() {
    let cadence = makeCadence(weeklyDigest: true, at: utcDate(2026, 3, 30, 7, 0))
    let nudges = tick(cadence, at: mondayMorning)
    XCTAssertEqual(nudges.map(\.kind), [.digest])
    XCTAssertEqual(nudges.first?.title, "Weekly digest")
  }

  func testDigestDoesNotFireTwiceSameMonday() {
    let cadence = makeCadence(weeklyDigest: true, at: utcDate(2026, 3, 30, 7, 0))
    _ = tick(cadence, at: mondayMorning)
    XCTAssertTrue(tick(cadence, at: mondayNoon).isEmpty)
    // And reschedules to the following Monday.
    let next = tick(cadence, at: utcDate(2026, 4, 6, 9, 1))
    XCTAssertTrue(next.contains { $0.kind == .digest })
  }

  func testMissedMondayIsSkippedNotFiredLate() {
    // A due from last Monday must not fire Tuesday — it reschedules.
    let cadence = makeCadence(weeklyDigest: true, at: utcDate(2026, 3, 23, 7, 0))
    XCTAssertFalse(
      tick(cadence, at: tuesday).contains { $0.kind == .digest },
      "the toast is Monday-morning; a week-late delivery is a bug")
  }

  func testDigestIsSuppressedDuringBreakAndUserPause() {
    let cadence = makeCadence(weeklyDigest: true, at: utcDate(2026, 3, 30, 7, 0))
    XCTAssertTrue(tick(cadence, at: mondayMorning, phase: .breaking).isEmpty)
    let paused = cadence.tick(
      at: mondayMorning,
      context: WellnessContext(
        schedulerPhase: .idle, pausedByUser: true, pausedByDetector: false))
    XCTAssertTrue(paused.isEmpty)
  }

  func testNoteDeliveredPreventsRelaunchRefire() {
    // App relaunched Monday 10:00 with a 9:05 delivery in the log.
    let cadence = makeCadence(weeklyDigest: true, at: mondayNoon)
    cadence.noteDelivered(.digest, at: utcDate(2026, 3, 30, 9, 5))
    XCTAssertTrue(tick(cadence, at: mondayNoon).isEmpty)
  }

  func testBodyComposesLastWeeksNumbers() {
    // now = Wednesday of week 14; last week = Mar 23–29.
    let now = utcDate(2026, 4, 1, 10, 0)
    var events: [LoggedEvent] = []
    // Last week: 3 dues, 2 taken, 1 skipped.
    for (day, kinds) in [
      (utcDate(2026, 3, 24, 11, 0), [BreakEventKind.breakDue, .breakStarted, .breakTaken]),
      (utcDate(2026, 3, 25, 11, 0), [BreakEventKind.breakDue, .breakSkipped]),
      (utcDate(2026, 3, 26, 11, 0), [BreakEventKind.breakDue, .breakStarted, .breakTaken]),
    ] {
      for (i, kind) in kinds.enumerated() {
        events.append(
          LoggedEvent(kind: kind, reason: "user", at: day.addingTimeInterval(TimeInterval(i))))
      }
    }
    let body = WeeklyDigest.body(events: events, now: now, calendar: utcCalendar)
    XCTAssertNotNil(body)
    XCTAssertTrue(body?.contains("2 taken") == true)
    XCTAssertTrue(body?.contains("1 skipped") == true)
    XCTAssertTrue(body?.contains("avg score") == true)
  }

  func testBodyIsNilForAnEmptyWeek() {
    XCTAssertNil(
      WeeklyDigest.body(events: [], now: mondayNoon, calendar: utcCalendar))
  }
}
