import XCTest

@testable import GazeKeeperCore

final class ScreenScoreTests: XCTestCase {

  private let day = Date(timeIntervalSince1970: 1_787_529_600)
  private var calendar: Calendar!

  override func setUp() {
    super.setUp()
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    calendar = utc
  }

  private func entry(
    _ kind: BreakEventKind, reason: String? = nil, minutesIntoDay: Double, duration: Double = 0
  ) -> LoggedEvent {
    LoggedEvent(
      kind: kind, reason: reason,
      at: day.addingTimeInterval(minutesIntoDay * 60), durationSeconds: duration)
  }

  private func score(_ events: [LoggedEvent], dayOffset: Int = 0) -> ScreenScore {
    ScreenScore.score(
      events: events, dayBucket: calendar.date(byAdding: .day, value: dayOffset, to: day)!,
      calendar: calendar)
  }

  private func discipline(_ events: [LoggedEvent]) -> Int {
    score(events).discipline
  }

  private func adherence(_ events: [LoggedEvent]) -> Int {
    score(events).adherence
  }

  private func breakCycle(at minute: Double) -> [LoggedEvent] {
    [
      entry(.breakDue, minutesIntoDay: minute),
      entry(.breakStarted, minutesIntoDay: minute + 0.5),
      entry(.breakTaken, minutesIntoDay: minute + 1),
    ]
  }

  func testEmptyHistoryScoresExactlyZero() {
    let result = score([])
    XCTAssertEqual(result.discipline, 0)
    XCTAssertEqual(result.adherence, 0)
    XCTAssertEqual(result.total, 0)
    XCTAssertTrue(result.isEmpty)
  }

  func testSessionWithoutDuesScoresZeroAndIsEmpty() {
    let result = score([
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.sessionEnded, minutesIntoDay: 60),
    ])
    XCTAssertEqual(result.total, 0)
    XCTAssertEqual(result.discipline, 0)
    XCTAssertTrue(
      result.isEmpty, "a session with zero dues is an empty day, not a perfect one")
  }

  func testNaturalBreakResolvesAnOpenDueLikeATakenBreak() {
    let result = score([
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 10),
      entry(.naturalBreak, minutesIntoDay: 25),
    ])
    XCTAssertEqual(
      result.adherence, 40,
      "the due resolves for free — the rest was real")
    XCTAssertEqual(result.breaksTaken, 1)
    XCTAssertEqual(result.discipline, 60, "no overdue accrues against a rest")
  }

  func testManualBreakCountsAsDueAndTaken() {
    let result = score([
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakStarted, minutesIntoDay: 10),
      entry(.breakTaken, minutesIntoDay: 11),
    ])
    XCTAssertEqual(result.breaksDue, 1)
    XCTAssertEqual(result.breaksTaken, 1)
    XCTAssertEqual(result.adherence, 40, "a voluntary break earns full adherence credit")
    XCTAssertEqual(result.discipline, 60, "resolved immediately, no overdue time")
    XCTAssertFalse(result.isEmpty)
    XCTAssertEqual(result.total, 100)
  }

  func testAllDuesTakenScoresForty() {
    for due in [1, 2, 3, 5] {
      var events = [entry(.sessionStarted, minutesIntoDay: 0)]
      for index in 0..<due {
        events.append(contentsOf: breakCycle(at: 60 + Double(index) * 20))
      }
      XCTAssertEqual(adherence(events), 40, "due=\(due)")
    }
  }

  func testSkipPenalizesHarderThanPostpone() {
    let withSkip: [LoggedEvent] = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 20),
      entry(.breakStarted, minutesIntoDay: 20.5),
      entry(.breakTaken, minutesIntoDay: 21),
      entry(.breakDue, minutesIntoDay: 41),
      entry(.breakSkipped, reason: "user", minutesIntoDay: 42),
    ]
    let withPostpone: [LoggedEvent] = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 20),
      entry(.breakStarted, minutesIntoDay: 20.5),
      entry(.breakTaken, minutesIntoDay: 21),
      entry(.breakDue, minutesIntoDay: 41),
      entry(.breakPostponed, reason: "user", minutesIntoDay: 42),
    ]

    let skipScore = score(withSkip)
    let postponeScore = score(withPostpone)
    XCTAssertLessThan(skipScore.adherence, postponeScore.adherence)
    XCTAssertEqual(
      skipScore.adherence, 16, "two dues, one taken: base 20 minus skip penalty 4")
    XCTAssertEqual(
      postponeScore.adherence, 18, "postpones only add penalty, they do not shrink due")
    XCTAssertEqual(postponeScore.breaksPostponed, 1)

    XCTAssertEqual(
      ScreenScore.penalty(for: .breakSkipped),
      ScreenScore.penalty(for: .breakPostponed) + ScreenScore.skipExtraPenalty)
  }

  func testSkipAppliesConstantPenaltyAcrossDueCounts() {
    for dueCount in [1, 2, 3] {
      var events = [entry(.sessionStarted, minutesIntoDay: 0)]
      for index in 0..<(dueCount - 1) {
        events.append(contentsOf: breakCycle(at: 10 + Double(index) * 20))
      }
      events.append(entry(.breakDue, minutesIntoDay: 90))
      events.append(entry(.breakSkipped, reason: "user", minutesIntoDay: 91))
      let takenBase = Int(
        (Double(dueCount - 1) / Double(dueCount) * 40).rounded(.down))
      let expected = clamp(
        takenBase - ScreenScore.penalty(for: .breakSkipped), max: 40)
      XCTAssertEqual(
        adherence(events), expected,
        "due=\(dueCount): taken \(dueCount - 1), one skip")
    }
  }

  func testPostponeAppliesConstantPenaltyWithoutShrinkingDue() {
    var events = [entry(.sessionStarted, minutesIntoDay: 0)]
    events.append(contentsOf: breakCycle(at: 10))
    events.append(contentsOf: breakCycle(at: 30))
    events.append(entry(.breakDue, minutesIntoDay: 50))
    events.append(entry(.breakPostponed, reason: "user", minutesIntoDay: 51))
    XCTAssertEqual(
      adherence(events),
      Int((2.0 / 3.0 * 40).rounded(.down)) - ScreenScore.penalty(for: .breakPostponed))
  }

  func testPostponeNeverRaisesScore() {
    var clean = [entry(.sessionStarted, minutesIntoDay: 0)]
    clean.append(contentsOf: breakCycle(at: 10))
    clean.append(contentsOf: breakCycle(at: 30))

    var postponed = clean
    postponed.append(entry(.breakDue, minutesIntoDay: 50))
    postponed.append(entry(.breakPostponed, reason: "user", minutesIntoDay: 51))

    XCTAssertLessThan(
      adherence(postponed), adherence(clean),
      "postponing must never make the score better")
  }

  func testSkipAndPostponeMagnitudesDifferByNamedConstant() {
    XCTAssertEqual(
      ScreenScore.penalty(for: .breakSkipped) - ScreenScore.penalty(for: .breakPostponed),
      ScreenScore.skipExtraPenalty)
    XCTAssertGreaterThan(
      ScreenScore.penalty(for: .breakSkipped), ScreenScore.penalty(for: .breakPostponed))
  }

  func testPenaltiesNeverDropBelowZeroNorAboveComponentMax() {
    let events = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 20),
      entry(.breakSkipped, reason: "user", minutesIntoDay: 21),
      entry(.breakPostponed, reason: "user", minutesIntoDay: 22),
    ]
    XCTAssertEqual(adherence(events), 0)
    XCTAssertLessThanOrEqual(score(events).total, 100)
    XCTAssertEqual(score(events).total, score(events).discipline + score(events).adherence)
  }

  private func clamp(_ value: Int, max maxValue: Int) -> Int {
    min(maxValue, Swift.max(0, value))
  }

  func testIdleAndOfficeHoursPostponesAreFree() {
    var events = [entry(.sessionStarted, minutesIntoDay: 0)]
    for index in 0..<3 {
      events.append(contentsOf: breakCycle(at: 20 + Double(index) * 20))
    }
    XCTAssertEqual(adherence(events), 40)

    let withIdlePostpone =
      [
        entry(.sessionStarted, minutesIntoDay: 0),
        entry(.breakDue, minutesIntoDay: 20),
        entry(.sessionEnded, minutesIntoDay: 40),
        entry(.breakPostponed, reason: "idle", minutesIntoDay: 21),
      ]
    let result = score(withIdlePostpone)
    XCTAssertEqual(result.breaksPostponed, 0, "idle postpones are not counted as user actions")
    XCTAssertEqual(adherence(withIdlePostpone), 0)
    XCTAssertEqual(
      result.discipline, 20,
      "the due left hanging for 20 minutes still costs overdue time")

    let officeHours = score([
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 20),
      entry(.sessionEnded, minutesIntoDay: 40),
      entry(.breakPostponed, reason: "office_hours", minutesIntoDay: 21),
    ])
    XCTAssertEqual(officeHours.breaksPostponed, 0)
  }

  func testAdherenceNeverDropsBelowZero() {
    var events = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 20),
      entry(.sessionEnded, minutesIntoDay: 40),
    ]
    for index in 0..<10 {
      events.append(entry(.breakSkipped, reason: "user", minutesIntoDay: 21 + Double(index)))
    }
    XCTAssertEqual(adherence(events), 0)
  }

  func testOverdueBreakDecayCurveIsLinearAndFlooredAtZero() {
    let session = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 10),
    ]

    XCTAssertEqual(discipline(session + [entry(.sessionEnded, minutesIntoDay: 15)]), 50)
    XCTAssertEqual(discipline(session + [entry(.sessionEnded, minutesIntoDay: 16)]), 48)
    XCTAssertEqual(discipline(session + [entry(.sessionEnded, minutesIntoDay: 25)]), 30)
    XCTAssertEqual(discipline(session + [entry(.sessionEnded, minutesIntoDay: 40)]), 0)
    XCTAssertEqual(
      discipline(
        session + [entry(.breakStarted, minutesIntoDay: 11)]
          + [entry(.sessionEnded, minutesIntoDay: 40)]),
      60, "starting the break resolves the due for free: the product did its job")
    XCTAssertEqual(
      discipline(
        session + [entry(.breakSkipped, reason: "user", minutesIntoDay: 12)]
          + [entry(.sessionEnded, minutesIntoDay: 40)]),
      56, "a skip two minutes late stops the overdue clock at the skip moment")
    XCTAssertEqual(
      discipline(session + [entry(.sessionEnded, minutesIntoDay: 120)]), 0)
  }

  func testOpenSessionUsesNowAsSessionEndWithoutExceedingCap() {
    let open = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 10),
    ]
    let freshResult = ScreenScore.score(
      events: open, dayBucket: day, calendar: calendar,
      now: day.addingTimeInterval(11 * 60))
    XCTAssertEqual(freshResult.discipline, 58)

    var longAgoCalendar = Calendar(identifier: .gregorian)
    longAgoCalendar.timeZone = TimeZone(identifier: "UTC")!
    let yesterday = longAgoCalendar.date(byAdding: .day, value: -1, to: day)!
    let stale = [
      LoggedEvent(kind: BreakEventKind.sessionStarted, at: yesterday),
      entry(.breakDue, minutesIntoDay: 10),
    ]
    XCTAssertEqual(discipline(stale), 0)
  }

  func testOverdueTimeAccumulatesAcrossSessions() {
    let events = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 10),
      entry(.sessionEnded, minutesIntoDay: 15),
      entry(.sessionStarted, minutesIntoDay: 240),
      entry(.breakDue, minutesIntoDay: 250),
      entry(.sessionEnded, minutesIntoDay: 260),
    ]
    let result = score(events)
    XCTAssertEqual(
      result.discipline, 30,
      "5 overdue minutes in the morning plus 10 in the afternoon cost 30 points")
    XCTAssertEqual(result.disciplineRaw, 30)
  }

  func testDueFromADeadSessionIsNotExcusedByTheNextSessionsBreak() {
    let events = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 10),
      entry(.sessionEnded, minutesIntoDay: 20),
      entry(.sessionStarted, minutesIntoDay: 100),
      entry(.breakStarted, minutesIntoDay: 100),
      entry(.breakTaken, minutesIntoDay: 101),
    ]
    let result = score(events)
    XCTAssertEqual(
      result.discipline, 40,
      "the abandoned due accrued 10 overdue minutes to its session end; the later break cannot forgive it"
    )
    XCTAssertEqual(result.breaksDue, 2)
    XCTAssertEqual(result.breaksTaken, 1)
  }

  func testEventsOutsideBucketDoNotCount() {
    let todayEvents = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 20),
      entry(.sessionEnded, minutesIntoDay: 40),
      entry(.breakSkipped, reason: "user", minutesIntoDay: 21),
    ]
    let result = score(todayEvents, dayOffset: -1)
    XCTAssertEqual(result.total, 0)
  }

  func testTotalNeverExceedsHundred() {
    var events = [entry(.sessionStarted, minutesIntoDay: 0)]
    for index in 0..<3 {
      events.append(entry(.breakTaken, minutesIntoDay: 20 + Double(index)))
    }
    let result = score(events)
    XCTAssertLessThanOrEqual(result.total, 100)
  }

  func testScoreComponentsExposeCountsForDashboard() {
    var events = [entry(.sessionStarted, minutesIntoDay: 0)]
    events.append(entry(.breakTaken, minutesIntoDay: 25, duration: 20))
    events.append(entry(.breakSkipped, reason: "user", minutesIntoDay: 50))
    events.append(entry(.breakSkipped, reason: "esc", minutesIntoDay: 80))
    events.append(entry(.breakPostponed, reason: "user", minutesIntoDay: 110))
    events.append(entry(.breakDue, minutesIntoDay: 111))
    events.append(entry(.detectorPaused, reason: "meetings", minutesIntoDay: 112))

    let result = score(events)
    XCTAssertEqual(result.breaksTaken, 1)
    XCTAssertEqual(result.breaksSkipped, 2)
    XCTAssertEqual(result.breaksPostponed, 1)
    XCTAssertEqual(
      result.breaksDue, 2, "the bare taken counts as a voluntary due, plus the explicit one")
  }

  func testFourteenDaySeriesBucketsPerLocalDay() {
    var events: [LoggedEvent] = []
    for offset in 0..<14 {
      let stamp = calendar.date(byAdding: .day, value: -offset, to: day)!
      events.append(LoggedEvent(kind: .breakTaken, at: stamp))
      if offset < 7 {
        events.append(LoggedEvent(kind: .breakSkipped, reason: "user", at: stamp))
      }
      events.append(
        LoggedEvent(kind: .breakDue, at: stamp))
      events.append(
        LoggedEvent(kind: .sessionStarted, at: stamp))
      events.append(
        LoggedEvent(
          kind: .sessionEnded, at: stamp.addingTimeInterval(60 * 60)))
    }

    let series = ScreenScore.dailySeries(
      events: events, endingAt: day, days: 14, calendar: calendar)

    XCTAssertEqual(series.count, 14)
    XCTAssertEqual(series[13].date, calendar.startOfDay(for: day))
    XCTAssertEqual(
      series[0].date, calendar.startOfDay(for: calendar.date(byAdding: .day, value: -13, to: day)!))
    XCTAssertTrue(series.allSatisfy { $0.score.total >= 0 && $0.score.total <= 100 })

    XCTAssertEqual(
      series[13].score.adherence, 16,
      "skip day: 1 taken of 2 dues is base 20 minus weighted skip penalty")
    XCTAssertEqual(series[7].score.adherence, 16, "skips land on the last 7 days only")
    XCTAssertEqual(series[6].score.adherence, 20, "no skip on older days")
    XCTAssertEqual(series[0].score.adherence, 20)
    for (index, point) in series.enumerated() {
      XCTAssertEqual(point.score.breaksTaken, 1, "index \(index)")
    }
  }

  func testSeriesShorterThanWindowPadsLeadingDays() {
    let series = ScreenScore.dailySeries(
      events: [], endingAt: day, days: 14, calendar: calendar)
    XCTAssertEqual(series.count, 14)
    XCTAssertTrue(series.allSatisfy { $0.score.total == 0 })
  }

  func testSeriesLastDayMatchesNowCutoffForOpenSession() {
    let events = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 30),
      entry(.breakTaken, minutesIntoDay: 31, duration: 20),
      entry(.breakDue, minutesIntoDay: 60),
    ]
    let now = day.addingTimeInterval(70 * 60)
    let todayBucket = calendar.startOfDay(for: now)
    let series = ScreenScore.dailySeries(
      events: events, endingAt: now, days: 14, calendar: calendar, now: now)
    let today = series.last!
    XCTAssertEqual(today.date, todayBucket)

    let direct = ScreenScore.score(
      events: events, dayBucket: todayBucket, calendar: calendar, now: now)
    XCTAssertEqual(today.score, direct)
  }

  func testSeriesWithoutNowKeepsLegacyRealClockCutoff() {
    let events = [
      entry(.sessionStarted, minutesIntoDay: 0),
      entry(.breakDue, minutesIntoDay: 30),
    ]
    let series = ScreenScore.dailySeries(
      events: events, endingAt: day, days: 14, calendar: calendar)
    XCTAssertEqual(series.count, 14)
  }

  func testEventCodableRoundTripPreservesDuration() throws {
    let original = LoggedEvent(
      kind: .breakTaken, reason: nil,
      at: Date(timeIntervalSince1970: 1_787_529_600), durationSeconds: 20.5)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(LoggedEvent.self, from: data)
    XCTAssertEqual(decoded, original)
    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("durationSeconds"))

    let bare = LoggedEvent(kind: .breakTaken, reason: nil, at: original.at)
    let bareData = try JSONEncoder().encode(bare)
    XCTAssertFalse(String(decoding: bareData, as: UTF8.self).contains("durationSeconds"))
  }

  func testDecodeRecognizesPersistedKindsAndLegacySpelling() throws {
    XCTAssertEqual(try BreakEventKind.decode("break_skipped"), .breakSkipped)
    XCTAssertEqual(try BreakEventKind.decode("break_postponed"), .breakPostponed)
    XCTAssertEqual(try BreakEventKind.decode("heads_up_started"), .breakDue)
    XCTAssertEqual(try BreakEventKind.decode("menu_revealed"), .menuRevealed)
  }

  func testDecodeRejectsUnknownKindsWithNoPrefixAliasing() {
    for raw in ["break_anything", "detector_paused_typo", "session_starts", "unknown_kind"] {
      XCTAssertThrowsError(
        try BreakEventKind.decode(raw),
        "an unknown kind must be rejected, never silently scored: \(raw)")
    }
  }

  func testMenuRevealedIsScoreNeutral() {

    let score = ScreenScore.score(
      events: [
        entry(.sessionStarted, minutesIntoDay: 10),
        entry(.menuRevealed, reason: "second_launch", minutesIntoDay: 20),
      ],
      dayBucket: day, calendar: calendar,
      now: day.addingTimeInterval(30 * 60))
    XCTAssertEqual(score.total, 0, "an open session with no dues is empty, not perfect")
    XCTAssertEqual(score.discipline, 0)
    XCTAssertEqual(score.breaksDue, 0)
    XCTAssertEqual(score.adherence, 0)
    XCTAssertTrue(score.isEmpty)
  }

  private func dayPoint(breaksDue: Int, breaksTaken: Int, offset: Int) -> DailyScorePoint {
    DailyScorePoint(
      date: calendar.date(byAdding: .day, value: offset, to: day)!,
      score: ScreenScore(
        discipline: 0, adherence: 0, disciplineRaw: 0,
        breaksDue: breaksDue, breaksTaken: breaksTaken,
        breaksSkipped: 0, breaksPostponed: 0))
  }

  func testStreakCountsConsecutiveDaysBackFromNow() {
    let series = (0..<5).map { dayPoint(breaksDue: 3, breaksTaken: 2, offset: -4 + $0) }
    XCTAssertEqual(ScreenScore.streak(series: series), 5)
  }

  func testStreakStopsAtADueDayWithNoTakenBreaks() {
    var series = (0..<5).map { dayPoint(breaksDue: 3, breaksTaken: 2, offset: -4 + $0) }
    series[3] = dayPoint(breaksDue: 3, breaksTaken: 0, offset: -1)
    XCTAssertEqual(ScreenScore.streak(series: series), 1)
  }

  func testStreakSkipsDaysWhereNothingWasDue() {
    var series = (0..<4).map { dayPoint(breaksDue: 3, breaksTaken: 2, offset: -3 + $0) }
    series.insert(dayPoint(breaksDue: 0, breaksTaken: 0, offset: -1), at: 3)
    XCTAssertEqual(
      ScreenScore.streak(series: series), 4,
      "a day off under office hours does not break the run")
  }

  func testStreakIsZeroWhenNothingHappened() {
    let series = (0..<3).map { dayPoint(breaksDue: 0, breaksTaken: 0, offset: -2 + $0) }
    XCTAssertEqual(ScreenScore.streak(series: series), 0)
  }

  func testStreakIgnoresAnUnfinishedToday() {
    var series = (0..<5).map { dayPoint(breaksDue: 3, breaksTaken: 2, offset: -4 + $0) }
    series.append(dayPoint(breaksDue: 2, breaksTaken: 0, offset: 0))
    XCTAssertEqual(
      ScreenScore.streak(series: series, today: day, calendar: calendar), 5,
      "a still-running day with dues but no takes has not broken the run")
  }

  func testStreakStillBreaksOnAFinishedDueDay() {
    var series = (0..<5).map { dayPoint(breaksDue: 3, breaksTaken: 2, offset: -4 + $0) }
    series.append(dayPoint(breaksDue: 2, breaksTaken: 0, offset: 0))
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
    XCTAssertEqual(ScreenScore.streak(series: series, today: tomorrow, calendar: calendar), 0)
  }

  func testWorkedBreakResolvesDueButEarnsNoRest() {
    let result = score([
      entry(.breakDue, minutesIntoDay: 0),
      entry(.breakStarted, minutesIntoDay: 0.5),
      entry(.breakWorked, minutesIntoDay: 1),
    ])
    XCTAssertEqual(result.breaksWorked, 1)
    XCTAssertEqual(result.breaksTaken, 0, "a worked-through break is not rest")
    XCTAssertEqual(result.breaksSkipped, 0)
    // The due resolved without a skip/postpone penalty — no overdue load.
    XCTAssertEqual(result.discipline, ScreenScore.disciplineMaximum)
  }

  func testWorkedBreakDoesNotCountTowardStreak() {
    let series = [
      DailyScorePoint(
        date: calendar.startOfDay(for: day),
        score: ScreenScore(
          discipline: 0, adherence: 0, disciplineRaw: 0,
          breaksDue: 2, breaksTaken: 0, breaksSkipped: 0,
          breaksPostponed: 0, breaksWorked: 1))
    ]
    XCTAssertEqual(
      ScreenScore.streak(series: series, today: nil, calendar: calendar), 0,
      "worked-through breaks do not keep a streak alive")
  }

  func testStreakCountsTodayWhenABreakWasTaken() {
    var series = (0..<3).map { dayPoint(breaksDue: 3, breaksTaken: 2, offset: -2 + $0) }
    series.append(dayPoint(breaksDue: 1, breaksTaken: 1, offset: 0))
    XCTAssertEqual(ScreenScore.streak(series: series, today: day, calendar: calendar), 4)
  }
}
