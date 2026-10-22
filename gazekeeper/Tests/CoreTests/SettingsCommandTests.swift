import XCTest

@testable import GazeKeeperCore

final class SettingsCommandTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("gk-setcmd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func applied(_ key: String, _ value: Any?, on base: GKSettingsV1 = GKSettingsV1()) -> (
    SettingsApplyOutcome, GKSettingsV1
  ) {
    var settings = base
    let outcome = GazeKeeperSettings.apply(key: key, value: value, to: &settings)
    return (outcome, settings)
  }

  private func clampReport(_ outcome: SettingsApplyOutcome) -> SettingsClampReport {
    guard case .clamped(let report) = outcome else {
      fatalError("test misuse: expected clamped, got \(outcome)")
    }
    return report
  }

  func testIntervalZeroClampsToOneWithExplicitReason() {
    let (outcome, settings) = applied("intervalMinutes", 0)
    let report = clampReport(outcome)
    XCTAssertEqual(report.requestedValue, "0")
    XCTAssertEqual(report.appliedValue, "1")
    XCTAssertTrue(report.reason.contains("between"), report.reason)
    XCTAssertEqual(settings.intervalMinutes, 1)
  }

  func testIntervalTenThousandClampsToTwoForty() {
    let (outcome, settings) = applied("intervalMinutes", 10_000)
    let report = clampReport(outcome)
    XCTAssertEqual(report.appliedValue, "240")
    XCTAssertEqual(settings.intervalMinutes, 240)
  }

  func testBreakSecondsBelowTenClampsUp() {
    let (outcome, settings) = applied("breakSeconds", 2)
    XCTAssertEqual(clampReport(outcome).appliedValue, "10")
    XCTAssertEqual(settings.breakSeconds, 10)
  }

  func testBreakSecondsAboveSixHundredClampsDown() {
    let (outcome, settings) = applied("breakSeconds", 900)
    XCTAssertEqual(clampReport(outcome).appliedValue, "600")
    XCTAssertEqual(settings.breakSeconds, 600)
  }

  func testBoundaryValuesApplyWithoutClamp() {
    for (key, value) in [
      ("intervalMinutes", 1), ("intervalMinutes", 240),
      ("breakSeconds", 10), ("breakSeconds", 600),
    ] {
      let (outcome, _) = applied(key, value)
      XCTAssertEqual(outcome, .applied, "\(key)=\(value)")
    }
  }

  func testOfficeHoursDaysAcceptsArrayOfWeekdayNames() {
    let (outcome, settings) = applied("officeHours.days", ["Mon", "Tue", "Wed", "Thu", "Fri"])
    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(settings.officeHours.days, Set(OfficeHoursSettings.weekdays))
  }

  func testOfficeHoursDaysEmptyMeansEveryDay() {
    let (outcome, settings) = applied("officeHours.days", [])
    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(settings.officeHours.days, OfficeHoursSettings.allDays)
  }

  func testOfficeHoursDaysRejectsUnknownNames() {
    let (outcome, _) = applied("officeHours.days", ["Funday"])
    guard case .invalidValue(let reason) = outcome else {
      return XCTFail("expected invalidValue, got \(outcome)")
    }
    XCTAssertTrue(reason.contains("weekday"), reason)
  }

  func testOfficeHoursStartRejectsOutOfRangeMinute() {
    let (outcome, _) = applied("officeHours.start", 2000)
    guard case .invalidValue = outcome else {
      return XCTFail("expected invalidValue, got \(outcome)")
    }
  }

  func testUnknownKeyReportsRejection() {
    let (outcome, settings) = applied("notARealKey", true)
    XCTAssertEqual(outcome, .unknownKey)
    XCTAssertEqual(settings, GKSettingsV1())
  }

  func testWrongTypeRejectedWithoutMutation() {
    let (outcome, settings) = applied("soundEnabled", "definitely")
    guard case .invalidValue(let reason) = outcome else {
      return XCTFail("expected invalidValue, got \(outcome)")
    }
    XCTAssertTrue(reason.contains("boolean"), reason)
    XCTAssertEqual(settings.soundEnabled, GKSettingsV1().soundEnabled)
  }

  func testMessagesBeyondLimitAreDroppedNotRejected() {
    let spam = (1...20).map { "message \($0)" }
    let (outcome, settings) = applied("messages", spam)
    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(settings.messages.count, GazeKeeperSettings.maxMessages)
  }

  func testWellnessAndDetectorKeysClampWithReasons() {
    let posture = applied("wellness.postureMinutes", 500)
    XCTAssertTrue(clampReport(posture.0).reason.contains("between"))
    XCTAssertEqual(posture.1.wellness.postureMinutes, GazeKeeperSettings.postureRange.upperBound)

    let sensitivity = applied("detectors.camera.sensitivity", -3)
    XCTAssertEqual(clampReport(sensitivity.0).appliedValue, "0.0")
    XCTAssertEqual(sensitivity.1.detectors["camera"]?.sensitivity, 0.0)
  }

  func testEverySchemaFieldRoundTripsThroughDiskAndRestart() throws {
    var mutated = GKSettingsV1()
    let changes: [(String, Any?)] = [
      ("intervalMinutes", 90),
      ("breakSeconds", 120),
      ("headsUpSeconds", 300),
      ("cooldownSeconds", 45),
      ("allowEsc", true),
      ("soundEnabled", false),
      ("launchAtLogin", true),
      ("messages", ["Eyes off screen", "Roll your shoulders"]),
      ("officeHours.enabled", true),
      ("officeHours.start", "08:15"),
      ("officeHours.end", 1080),
      ("officeHours.weekdaysOnly", false),
      ("wellness.enabled", false),
      ("wellness.postureMinutes", 60),
      ("wellness.blinkMinutes", 12),
      ("detectors.camera.enabled", false),
      ("detectors.fullscreen.sensitivity", 0.8),
    ]
    for (key, value) in changes {
      let (outcome, updated) = applied(key, value, on: mutated)
      guard case .applied = outcome else {
        return XCTFail("\(key) should apply cleanly, got \(outcome)")
      }
      mutated = updated
    }

    let store = SettingsStore(directory: directory)
    store.persist(mutated)

    let reloadedResult = SettingsStore(directory: directory).load()
    guard case .success(let restored) = reloadedResult else {
      return XCTFail("\(reloadedResult)")
    }
    XCTAssertEqual(restored.intervalMinutes, 90)
    XCTAssertEqual(restored.breakSeconds, 120)
    XCTAssertEqual(restored.headsUpSeconds, 300)
    XCTAssertEqual(restored.cooldownSeconds, 45)
    XCTAssertTrue(restored.allowEsc)
    XCTAssertFalse(restored.soundEnabled)
    XCTAssertTrue(restored.launchAtLogin)
    XCTAssertEqual(restored.messages, ["Eyes off screen", "Roll your shoulders"])
    XCTAssertTrue(restored.officeHours.enabled)
    XCTAssertEqual(restored.officeHours.startMinuteOfDay, 8 * 60 + 15)
    XCTAssertEqual(restored.officeHours.endMinuteOfDay, 18 * 60)
    XCTAssertEqual(restored.officeHours.days, OfficeHoursSettings.allDays)
    XCTAssertFalse(restored.wellness.enabled)
    XCTAssertEqual(restored.wellness.postureMinutes, 60)
    XCTAssertEqual(restored.wellness.blinkMinutes, 12)
    XCTAssertEqual(restored.detectors["camera"]?.enabled, false)
    XCTAssertEqual(restored.detectors["fullscreen"]?.sensitivity ?? 0, 0.8, accuracy: 0.0001)

    let document =
      try JSONSerialization.jsonObject(with: Data(contentsOf: store.settingsFileURL))
      as? [String: Any]
    XCTAssertEqual((document?["version"] as? NSNumber)?.intValue, 1)
  }

  func testDaysPersistAsSortedWeekdayNamesInJSON() throws {
    var settings = GKSettingsV1()
    settings.officeHours.days = OfficeHoursSettings.daySet(from: ["sun", "wed"])
    let store = SettingsStore(directory: directory)
    store.persist(settings)

    let raw =
      try JSONSerialization.jsonObject(with: Data(contentsOf: store.settingsFileURL))
      as! [String: Any]
    let payload = raw["settings"] as! [String: Any]
    let officeHours = payload["officeHours"] as! [String: Any]
    XCTAssertEqual(officeHours["days"] as? [String], ["sun", "wed"])
  }
}
