import XCTest

@testable import GazeKeeperCore

final class WellnessCadenceTests: XCTestCase {

  private let epoch = Date(timeIntervalSince1970: 1_775_000_000)

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
  }

  private func utcDate(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int
  ) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return utcCalendar.date(from: components)!
  }

  private func makeSettings(
    postureMinutes: Int = 30,
    blinkMinutes: Int = 5,
    wellnessEnabled: Bool = true,
    quietHours: WellnessQuietHours = WellnessQuietHours(),
    postureMessage: String? = nil,
    blinkMessage: String? = nil
  ) -> GKSettingsV1 {
    var settings = GKSettingsV1()
    settings.wellness = WellnessSettings(
      enabled: wellnessEnabled, postureMinutes: postureMinutes, blinkMinutes: blinkMinutes)
    settings.wellness.quietHours = quietHours
    settings.wellness.postureMessage = postureMessage
    settings.wellness.blinkMessage = blinkMessage
    return settings
  }

  private func makeCadence(
    settings: GKSettingsV1, at start: Date? = nil, calendar: Calendar = .current
  ) -> WellnessCadence {
    WellnessCadence(settings: settings, now: start ?? epoch, calendar: calendar)
  }

  private func fire(
    _ cadence: WellnessCadence, at date: Date,
    phase: GazeKeeperPhase = .idle, userPaused: Bool = false, detectorPaused: Bool = false
  ) -> [WellnessNudge] {
    cadence.tick(
      at: date,
      context: WellnessContext(
        schedulerPhase: phase, pausedByUser: userPaused, pausedByDetector: detectorPaused))
  }

  private func quietWindow(startMinute: Int, endMinute: Int) -> WellnessQuietHours {
    WellnessQuietHours(enabled: true, startMinuteOfDay: startMinute, endMinuteOfDay: endMinute)
  }

  private func kinds(_ nudges: [WellnessNudge]) -> [WellnessNudgeKind] {
    nudges.map(\.kind)
  }

  func testDefaultScheduleFiresPostureAtThirtyMinutesAndBlinkEveryFiveMinutes() {
    let cadence = makeCadence(settings: makeSettings())

    XCTAssertEqual(cadence.snapshot().nextPostureAt, epoch.addingTimeInterval(30 * 60))
    XCTAssertEqual(cadence.snapshot().nextBlinkAt, epoch.addingTimeInterval(5 * 60))

    XCTAssertTrue(fire(cadence, at: epoch.addingTimeInterval(4 * 60)).isEmpty)
    XCTAssertEqual(kinds(fire(cadence, at: epoch.addingTimeInterval(5 * 60))), [.blink])
    XCTAssertEqual(
      kinds(fire(cadence, at: epoch.addingTimeInterval(29 * 60))), [.blink],
      "an overdue blink catches up at the first probe tick past its due")

    let atThirty = fire(cadence, at: epoch.addingTimeInterval(30 * 60))
    XCTAssertEqual(kinds(atThirty), [.posture], "posture comes due exactly at 30 minutes")

    var blinkCount = 0
    var postureCount = 0
    for second in stride(from: 31 * 60.0, through: 31 * 60.0 + 3600, by: 15) {
      let fired = fire(cadence, at: epoch.addingTimeInterval(second))
      blinkCount += fired.filter { $0.kind == .blink }.count
      postureCount += fired.filter { $0.kind == .posture }.count
    }
    XCTAssertEqual(blinkCount, 12, "blink cadence stays on its own 5-minute schedule")
    XCTAssertEqual(postureCount, 2, "posture cadence stays on its own 30-minute schedule")
  }

  func testNudgesAreSeparateNotificationsWithDistinctTitlesAndCopy() {
    let cadence = makeCadence(settings: makeSettings())
    let fired = fire(cadence, at: epoch.addingTimeInterval(30 * 60))
    XCTAssertEqual(fired.count, 2, "each kind is its own notification, never merged")
    let posture = fired.first { $0.kind == .posture }
    let blink = fired.first { $0.kind == .blink }
    XCTAssertEqual(posture?.title, "Posture check")
    XCTAssertEqual(blink?.title, "Blink break")
    XCTAssertEqual(posture?.body, WellnessCadence.defaultPostureBody)
    XCTAssertEqual(blink?.body, WellnessCadence.defaultBlinkBody)
  }

  func testSuppressionDuringBreakingSuppressesBothKinds() {
    let cadence = makeCadence(settings: makeSettings())

    let duringBreak = fire(cadence, at: epoch.addingTimeInterval(30 * 60), phase: .breaking)
    XCTAssertTrue(duringBreak.isEmpty, "no nudge may fire while a break overlay is up")

    let afterLift = fire(cadence, at: epoch.addingTimeInterval(62 * 60), phase: .idle)
    XCTAssertEqual(Set(kinds(afterLift)), [.posture, .blink], "both catch up once after the break")
    XCTAssertTrue(fire(cadence, at: epoch.addingTimeInterval(62 * 60 + 15)).isEmpty)
  }

  func testSuppressionDuringHeadsUpSuppressesBothKinds() {
    let cadence = makeCadence(settings: makeSettings())

    let duringHeadsUp = fire(cadence, at: epoch.addingTimeInterval(30 * 60), phase: .headsUp)
    XCTAssertTrue(duringHeadsUp.isEmpty, "a pending break makes nudges redundant")

    let afterLift = fire(cadence, at: epoch.addingTimeInterval(62 * 60), phase: .idle)
    XCTAssertEqual(Set(kinds(afterLift)), [.posture, .blink])
  }

  func testSuppressionDuringDetectorPauseSuppressesBothKinds() {
    let cadence = makeCadence(settings: makeSettings())

    let duringMeeting = fire(
      cadence, at: epoch.addingTimeInterval(30 * 60), phase: .idle, detectorPaused: true)
    XCTAssertTrue(duringMeeting.isEmpty, "meetings and video silence both nudges")

    let afterResume = fire(cadence, at: epoch.addingTimeInterval(62 * 60), phase: .idle)
    XCTAssertEqual(Set(kinds(afterResume)), [.posture, .blink])
  }

  func testUserPauseSuppressesPostureOnlyWhileBlinkContinues() {
    let cadence = makeCadence(settings: makeSettings())

    let duringUserPause = fire(cadence, at: epoch.addingTimeInterval(30 * 60), userPaused: true)
    XCTAssertEqual(
      kinds(duringUserPause), [.blink],
      "user pause freezes scheduling but blinking still matters on screen")

    let afterPause = fire(cadence, at: epoch.addingTimeInterval(35 * 60), userPaused: false)
    XCTAssertEqual(
      Set(kinds(afterPause)), [.posture, .blink],
      "the withheld posture nudge delivers once the pause lifts, alongside blink's own slot")

    let later = fire(cadence, at: epoch.addingTimeInterval(60 * 60), userPaused: false)
    XCTAssertEqual(
      kinds(later), [.blink],
      "each cadence keeps running independently afterwards: blink's next slot is due first")
  }

  func testSuppressedDuesDoNotStackAcrossLongSuppression() {
    let cadence = makeCadence(settings: makeSettings())

    var suppressedTotal = 0
    for minute in [5, 10, 15, 20, 25, 30, 35, 40] {
      suppressedTotal +=
        fire(cadence, at: epoch.addingTimeInterval(TimeInterval(minute * 60)), phase: .breaking)
        .count
    }
    XCTAssertEqual(suppressedTotal, 0)

    let afterLift = fire(cadence, at: epoch.addingTimeInterval(45 * 60), phase: .idle)
    XCTAssertEqual(
      Set(kinds(afterLift)), [.posture, .blink],
      "eight suppressed blink dues produce one catch-up per kind, not eight")

    let nextRound = fire(cadence, at: epoch.addingTimeInterval(65 * 60), phase: .idle)
    XCTAssertEqual(kinds(nextRound), [.blink])
    XCTAssertTrue(fire(cadence, at: epoch.addingTimeInterval(65 * 60 + 15)).isEmpty)
  }

  func testQuietHoursSuppressBothKindsInsideOvernightWindow() {
    let calendar = utcCalendar
    let noon = utcDate(2026, 8, 19, 12, 0)
    let cadence = makeCadence(
      settings: makeSettings(quietHours: quietWindow(startMinute: 22 * 60, endMinute: 8 * 60)),
      at: noon,
      calendar: calendar)

    let daytime = fire(cadence, at: utcDate(2026, 8, 19, 12, 30))
    XCTAssertEqual(
      Set(kinds(daytime)), [.posture, .blink], "before the window opens all is normal")

    XCTAssertTrue(
      fire(cadence, at: utcDate(2026, 8, 19, 23, 30)).isEmpty,
      "23:30 falls inside the 22:00-08:00 quiet window")
    XCTAssertTrue(
      fire(cadence, at: utcDate(2026, 8, 20, 7, 59)).isEmpty,
      "07:59 is still inside the overnight window")

    let afterWindow = fire(cadence, at: utcDate(2026, 8, 20, 8, 10))
    XCTAssertEqual(
      Set(kinds(afterWindow)), [.posture, .blink],
      "past the window end both withheld nudges deliver once")

    let resumedCadence = fire(cadence, at: utcDate(2026, 8, 20, 8, 30))
    XCTAssertEqual(
      kinds(resumedCadence), [.blink],
      "normal intervals resume: blink's next slot lands 5 minutes after its delivery")
  }

  func testQuietHoursDisabledNeverSuppresses() {
    let off = WellnessQuietHours(enabled: false, startMinuteOfDay: 0, endMinuteOfDay: 1440)
    let cadence = makeCadence(settings: makeSettings(quietHours: off))

    let noonish = epoch.addingTimeInterval(12 * 60 * 60)
    XCTAssertEqual(Set(kinds(fire(cadence, at: noonish))), [.posture, .blink])
  }

  func testCustomMessagesOverrideDefaultCopyWhenConfigured() {
    let custom = makeSettings(
      postureMessage: "Roll those shoulders back",
      blinkMessage: "Full slow blinks, three times"
    )
    let customCadence = makeCadence(settings: custom)
    let fired = fire(customCadence, at: epoch.addingTimeInterval(30 * 60))
    let posture = fired.first { $0.kind == .posture }
    let blink = fired.first { $0.kind == .blink }
    XCTAssertEqual(posture?.title, "Posture check")
    XCTAssertEqual(posture?.body, "Roll those shoulders back")
    XCTAssertEqual(blink?.title, "Blink break")
    XCTAssertEqual(blink?.body, "Full slow blinks, three times")
  }

  func testIntervalChangesHotApplyWithoutRestart() {
    let cadence = makeCadence(settings: makeSettings(postureMinutes: 60, blinkMinutes: 30))

    let updateAt = epoch.addingTimeInterval(20 * 60)
    cadence.updateSettings(makeSettings(postureMinutes: 30, blinkMinutes: 5), at: updateAt)

    XCTAssertEqual(
      cadence.snapshot().nextPostureAt, epoch.addingTimeInterval(50 * 60),
      "shortening an interval pulls the pending due earlier without a restart")
    XCTAssertTrue(fire(cadence, at: updateAt).isEmpty)

    cadence.updateSettings(makeSettings(postureMinutes: 120, blinkMinutes: 120), at: updateAt)
    XCTAssertEqual(
      cadence.snapshot().nextPostureAt, epoch.addingTimeInterval(50 * 60),
      "lengthening an interval never postpones an already-scheduled due")

    let due = cadence.snapshot().nextPostureAt
    XCTAssertEqual(Set(kinds(fire(cadence, at: due))), [.posture, .blink])
    XCTAssertEqual(
      cadence.snapshot().nextPostureAt, due.addingTimeInterval(120 * 60),
      "subsequent slots honor the latest configured interval")
  }

  func testShrinkingIntervalSchedulesNearTermDeliveryWithoutRestart() {
    let cadence = makeCadence(settings: makeSettings(postureMinutes: 60, blinkMinutes: 60))
    cadence.updateSettings(makeSettings(postureMinutes: 5, blinkMinutes: 5), at: epoch)

    XCTAssertEqual(
      cadence.snapshot().nextPostureAt, epoch.addingTimeInterval(5 * 60),
      "a much smaller interval reschedules the due into the near future")
    XCTAssertTrue(fire(cadence, at: epoch.addingTimeInterval(60)).isEmpty)

    let due = cadence.snapshot().nextPostureAt
    XCTAssertEqual(kinds(fire(cadence, at: due)), [.posture, .blink])
  }

  func testDisablingWellnessStopsEveryNudge() {
    let cadence = makeCadence(settings: makeSettings())
    cadence.updateSettings(makeSettings(wellnessEnabled: false), at: epoch)

    for second in stride(from: 300.0, through: 3600.0, by: 60) {
      XCTAssertTrue(fire(cadence, at: epoch.addingTimeInterval(second)).isEmpty)
    }
    XCTAssertTrue(fire(cadence, at: epoch.addingTimeInterval(7200)).isEmpty)
  }

  func testReEnablingWellnessRestartsCleanCadences() {
    let cadence = makeCadence(settings: makeSettings())
    cadence.updateSettings(makeSettings(wellnessEnabled: false), at: epoch)
    let enableAt = epoch.addingTimeInterval(10 * 60)
    cadence.updateSettings(makeSettings(), at: enableAt)

    XCTAssertEqual(
      cadence.snapshot().nextPostureAt, enableAt.addingTimeInterval(30 * 60),
      "re-enable anchors fresh intervals from the enable moment")
    XCTAssertEqual(cadence.snapshot().nextBlinkAt, enableAt.addingTimeInterval(5 * 60))

    XCTAssertTrue(fire(cadence, at: enableAt.addingTimeInterval(4 * 60)).isEmpty)
    XCTAssertEqual(kinds(fire(cadence, at: enableAt.addingTimeInterval(5 * 60))), [.blink])
    XCTAssertEqual(
      Set(kinds(fire(cadence, at: enableAt.addingTimeInterval(30 * 60)))),
      [.posture, .blink],
      "posture arrives on its fresh slot and blink rides its own next interval")
  }

  func testSnapshotExposesIndependentNextTargetsAndCounts() {
    let cadence = makeCadence(settings: makeSettings())
    var snap = cadence.snapshot()
    XCTAssertEqual(snap.nextPostureAt, epoch.addingTimeInterval(30 * 60))
    XCTAssertEqual(snap.nextBlinkAt, epoch.addingTimeInterval(5 * 60))
    XCTAssertNil(snap.lastPostureAt)
    XCTAssertNil(snap.lastBlinkAt)
    XCTAssertEqual(snap.sentPostureCount, 0)
    XCTAssertEqual(snap.sentBlinkCount, 0)

    _ = fire(cadence, at: epoch.addingTimeInterval(5 * 60))
    snap = cadence.snapshot()
    XCTAssertEqual(snap.sentBlinkCount, 1)
    XCTAssertEqual(snap.lastBlinkAt, epoch.addingTimeInterval(5 * 60))
    XCTAssertEqual(snap.nextBlinkAt, epoch.addingTimeInterval(10 * 60))
    XCTAssertEqual(snap.sentPostureCount, 0)
  }

  func testQuietHourBoundarySemanticsMatchOfficeHoursStyle() {
    let calendar = utcCalendar
    let start = utcDate(2026, 8, 19, 12, 0)

    let inclusiveStart = makeCadence(
      settings: makeSettings(quietHours: quietWindow(startMinute: 22 * 60, endMinute: 23 * 60)),
      at: start, calendar: calendar)
    XCTAssertEqual(
      kinds(fire(inclusiveStart, at: utcDate(2026, 8, 19, 22, 0))), [],
      "start minute is inside the window")
    XCTAssertEqual(
      Set(kinds(fire(inclusiveStart, at: utcDate(2026, 8, 19, 23, 0)))),
      [.posture, .blink],
      "end minute is already outside the window")

    let exclusiveEnd = makeCadence(
      settings: makeSettings(quietHours: quietWindow(startMinute: 12 * 60, endMinute: 13 * 60)),
      at: start, calendar: calendar)
    XCTAssertEqual(
      kinds(fire(exclusiveEnd, at: utcDate(2026, 8, 19, 12, 59))), [],
      "last minute before the end is still quiet")
    XCTAssertEqual(
      Set(kinds(fire(exclusiveEnd, at: utcDate(2026, 8, 19, 13, 0)))),
      [.posture, .blink],
      "the end minute itself is open")
  }
}
