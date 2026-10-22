import XCTest

@testable import GazeKeeperCore

final class OffsetClockTests: XCTestCase {

  func testSystemClockReturnsCurrentDate() {
    let clock = SystemClock()
    let before = Date()
    let produced = clock.now()
    let after = Date()
    XCTAssertTrue(produced >= before && produced <= after)
  }

  func testOffsetClockShiftsBaseTime() {
    let clock = OffsetClock(base: FixedClock(date: Date(timeIntervalSince1970: 1_000)))
    XCTAssertEqual(clock.now().timeIntervalSince1970, 1_000)
    clock.setOffset(300)
    XCTAssertEqual(clock.now().timeIntervalSince1970, 1_300)
    clock.setOffset(-120)
    XCTAssertEqual(clock.now().timeIntervalSince1970, 880)
  }

  func testOffsetClockShiftingAccumulates() {
    let clock = OffsetClock(offset: 10, base: FixedClock(date: Date(timeIntervalSince1970: 500)))
    clock.shiftOffset(bySeconds: 40)
    XCTAssertEqual(clock.now().timeIntervalSince1970, 550)
    clock.shiftOffset(bySeconds: -100)
    XCTAssertEqual(clock.now().timeIntervalSince1970, 450)
  }
}

struct FixedClock: GKClock {
  let date: Date
  func now() -> Date { date }
}

final class SettingsSchemaTests: XCTestCase {

  private func applied(_ key: String, _ value: Any?, on base: GKSettingsV1 = GKSettingsV1()) -> (
    SettingsApplyOutcome, GKSettingsV1
  ) {
    var settings = base
    let outcome = GazeKeeperSettings.apply(key: key, value: value, to: &settings)
    return (outcome, settings)
  }

  func testIntervalWithinBoundsApplies() {
    let (outcome, settings) = applied("intervalMinutes", 45)
    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(settings.intervalMinutes, 45)
  }

  func testIntervalZeroClampsToOneWithReport() {
    let (outcome, settings) = applied("intervalMinutes", 0)
    guard case .clamped(let report) = outcome else { return XCTFail("expected clamped") }
    XCTAssertEqual(report.appliedValue, "1")
    XCTAssertEqual(report.requestedValue, "0")
    XCTAssertEqual(settings.intervalMinutes, GazeKeeperSettings.intervalRange.lowerBound)
  }

  func testIntervalAboveBoundsClampsToMax() {
    let (outcome, settings) = applied("intervalMinutes", 10_000)
    XCTAssertNotNil(clampReport(from: outcome))
    XCTAssertEqual(settings.intervalMinutes, GazeKeeperSettings.intervalRange.upperBound)
  }

  func testBreakSecondsClampsBothDirections() {
    let low = applied("breakSeconds", 1)
    XCTAssertEqual(low.1.breakSeconds, GazeKeeperSettings.breakRange.lowerBound)
    let high = applied("breakSeconds", 999_999)
    XCTAssertEqual(high.1.breakSeconds, GazeKeeperSettings.breakRange.upperBound)
  }

  func testAllowEscRoundTrip() {
    let (outcome, settings) = applied("allowEsc", true)
    XCTAssertEqual(outcome, .applied)
    XCTAssertTrue(settings.allowEsc)
  }

  func testUnknownKeyRejected() {
    let (outcome, _) = applied("nonsenseKey", 5)
    XCTAssertEqual(outcome, .unknownKey)
  }

  func testWrongTypeRejected() {
    let (outcome, _) = applied("intervalMinutes", "soon")
    guard case .invalidValue = outcome else { return XCTFail("expected invalidValue") }
  }

  func testMessagesReplacedAndSanitized() {
    let (outcome, settings) = applied("messages", ["Stay sharp", "", "Rest eyes"])
    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(settings.messages, ["Stay sharp", "Rest eyes"])
  }

  func testOfficeHoursAcceptsHHMMString() {
    let (outcome, settings) = applied("officeHours.start", "09:30")
    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(settings.officeHours.startMinuteOfDay, 9 * 60 + 30)
  }

  func testDetectorSensitivityClamps() {
    let (outcome, settings) = applied("detectors.fullscreen.sensitivity", 7.5)
    XCTAssertNotNil(clampReport(from: outcome))
    XCTAssertEqual(settings.detectors["fullscreen"]?.sensitivity, 1.0)
  }

  func testFractionalIntervalRejectedWithoutMutation() {
    let (outcome, settings) = applied("intervalMinutes", 20.7)
    guard case .invalidValue(let reason) = outcome else { return XCTFail("expected invalidValue") }
    XCTAssertTrue(reason.contains("integer"), reason)
    XCTAssertEqual(settings.intervalMinutes, GKSettingsV1().intervalMinutes)
  }

  func testFractionalBreakSecondsRejected() {
    let (outcome, settings) = applied("breakSeconds", 30.5)
    guard case .invalidValue = outcome else { return XCTFail("expected invalidValue") }
    XCTAssertEqual(settings.breakSeconds, GKSettingsV1().breakSeconds)
  }
}

private func clampReport(from outcome: SettingsApplyOutcome) -> SettingsClampReport? {
  if case .clamped(let report) = outcome { return report }
  return nil
}

final class SettingsStoreTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("gk-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
  }

  func testFirstLoadWritesDefaultsFile() throws {
    let store = SettingsStore(directory: directory)
    let result = store.load()
    guard case .success(let settings) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(settings.intervalMinutes, 20)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.settingsFileURL.path))
  }

  func testPersistedValuesRoundTrip() throws {
    let store = SettingsStore(directory: directory)
    var settings = GKSettingsV1()
    settings.intervalMinutes = 33
    settings.allowEsc = true
    store.persist(settings)

    let reloaded = store.load()
    guard case .success(let restored) = reloaded else { return XCTFail("\(reloaded)") }
    XCTAssertEqual(restored.intervalMinutes, 33)
    XCTAssertTrue(restored.allowEsc)
  }

  func testV0DocumentMigratesAndBacksUpOriginal() throws {
    let legacyURL = directory.appendingPathComponent("settings.json")
    try writeJSON(["version": 0, "intervalMinutes": 15, "allowEsc": true], to: legacyURL)

    let store = SettingsStore(directory: directory)
    let result = store.load()
    guard case .success(let migrated) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(migrated.intervalMinutes, 15)
    XCTAssertTrue(migrated.allowEsc)
    XCTAssertEqual(migrated.wellness.postureMinutes, 30)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("settings.backup.json").path))

    let persisted = try JSONDecoder().decode(
      VersionedSettings.self, from: Data(contentsOf: legacyURL))
    XCTAssertEqual(persisted.version, 1)
  }

  func testCorruptFileRecoversWithBackup() throws {
    let url = directory.appendingPathComponent("settings.json")
    try Data("{{{ not json".utf8).write(to: url)

    let store = SettingsStore(directory: directory)
    let result = store.load()
    guard case .success(let recovered) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(recovered, GKSettingsV1())
    let backup = try Data(contentsOf: directory.appendingPathComponent("settings.backup.json"))
    XCTAssertEqual(String(decoding: backup, as: UTF8.self), "{{{ not json")
  }

  func testFutureVersionRecoversToDefaults() throws {
    let url = directory.appendingPathComponent("settings.json")
    try writeJSON(["version": 99, "settings": ["intervalMinutes": 60]], to: url)

    let store = SettingsStore(directory: directory)
    let result = store.load()
    guard case .success(let recovered) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(recovered.intervalMinutes, 20)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("settings.backup.json").path))
  }
}
