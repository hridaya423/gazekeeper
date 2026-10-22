import XCTest

@testable import GazeKeeperCore

final class SettingsMigrationTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("gk-migrations-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var settingsURL: URL {
    directory.appendingPathComponent("settings.json")
  }

  private var backupURL: URL {
    directory.appendingPathComponent("settings.backup.json")
  }

  private func seed(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: settingsURL)
  }

  private func seedRaw(_ contents: String) throws {
    try Data(contents.utf8).write(to: settingsURL)
  }

  private func loadedSettings(
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> GKSettingsV1 {
    let result = SettingsStore(directory: directory).load()
    guard case .success(let settings) = result else {
      XCTFail("expected success, got \(result)", file: file, line: line)
      throw XCTestError(.failureWhileWaiting)
    }
    return settings
  }

  private var appearanceURL: URL {
    directory.appendingPathComponent("appearance.json")
  }

  private func seedAppearance(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys])
    try data.write(to: appearanceURL)
  }

  @discardableResult
  private func assertBackupExists(
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> Data {
    let data = try XCTUnwrap(
      try? Data(contentsOf: backupURL),
      "expected backup beside original",
      file: file,
      line: line
    )
    return data
  }

  func testV0FlatDocumentMigratesKnownFieldsAndFillsDefaults() throws {
    try seed(["version": 0, "intervalMinutes": 45, "breakSeconds": 30, "allowEsc": true])
    let migrated = try loadedSettings()
    XCTAssertEqual(migrated.intervalMinutes, 45)
    XCTAssertEqual(migrated.breakSeconds, 30)
    XCTAssertTrue(migrated.allowEsc)
    XCTAssertEqual(migrated.wellness.postureMinutes, 30)
    XCTAssertTrue(migrated.detectors["camera"]?.enabled ?? false)
    XCTAssertEqual(SettingsMigrator.currentVersion, 1)
  }

  func testV0NestedSettingsDocumentMigrates() throws {
    try seed([
      "version": 0,
      "settings": ["intervalMinutes": 50, "messages": ["Stretch"]],
    ])
    let migrated = try loadedSettings()
    XCTAssertEqual(migrated.intervalMinutes, 50)
    XCTAssertEqual(migrated.messages, ["Stretch"])
  }

  func testV0MigrationIgnoresUnknownKeys() throws {
    try seed(["version": 0, "legacyWidget": true, "intervalMinutes": 35])
    let migrated = try loadedSettings()
    XCTAssertEqual(migrated.intervalMinutes, 35)
    XCTAssertEqual(migrated.soundEnabled, GKSettingsV1().soundEnabled)
  }

  func testV0MigrationClampsOutOfRangeLegacyValues() throws {
    try seed(["version": 0, "intervalMinutes": 9_999, "breakSeconds": 1])
    let migrated = try loadedSettings()
    XCTAssertEqual(migrated.intervalMinutes, GazeKeeperSettings.intervalRange.upperBound)
    XCTAssertEqual(migrated.breakSeconds, GazeKeeperSettings.breakRange.lowerBound)
    try assertBackupExists()
  }

  func testDocumentWithoutVersionMarkerTreatedAsV0() throws {
    try seed(["intervalMinutes": 25])
    let migrated = try loadedSettings()
    XCTAssertEqual(migrated.intervalMinutes, 25)
  }

  func testV0MigrationPersistsVersionOneFileAndBacksUpOriginal() throws {
    try seed(["version": 0, "intervalMinutes": 15, "allowEsc": true])
    _ = try loadedSettings()

    let backup = try assertBackupExists()
    XCTAssertGreaterThan(backup.count, 0)

    let persisted = try JSONDecoder().decode(
      VersionedSettings.self, from: Data(contentsOf: settingsURL))
    XCTAssertEqual(persisted.version, 1)
    XCTAssertEqual(persisted.settings.intervalMinutes, 15)
  }

  func testMigratorIsPureAcrossCalls() throws {
    let document: [String: Any] = ["version": 0, "intervalMinutes": 42, "allowEsc": true]
    let pristine = try JSONSerialization.jsonObject(
      with: JSONSerialization.data(withJSONObject: document))

    let first = try SettingsMigrator.migrate(document)
    let second = try SettingsMigrator.migrate(document)

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.version, 1)
    XCTAssertEqual(first.settings.intervalMinutes, 42)
    XCTAssertEqual(document as NSDictionary, pristine as? NSDictionary)
  }

  func testCorruptJSONRecoversToDefaultsWithByteIdenticalBackup() throws {
    try seedRaw("{{{ not json at all")
    let recovered = try loadedSettings()
    XCTAssertEqual(recovered, GKSettingsV1())

    let backup = try assertBackupExists()
    XCTAssertEqual(String(decoding: backup, as: UTF8.self), "{{{ not json at all")

    let rewritten = try JSONDecoder().decode(
      VersionedSettings.self, from: Data(contentsOf: settingsURL))
    XCTAssertEqual(rewritten.version, 1)
    XCTAssertEqual(rewritten.settings, GKSettingsV1())
  }

  func testEmptyFileRecoversToDefaultsWithBackup() throws {
    try seedRaw("")
    let recovered = try loadedSettings()
    XCTAssertEqual(recovered, GKSettingsV1())
    try assertBackupExists()
  }

  func testJSONScalarRootRecoversToDefaultsWithBackup() throws {
    try seedRaw("[1, 2, 3]")
    let recovered = try loadedSettings()
    XCTAssertEqual(recovered, GKSettingsV1())
    try assertBackupExists()
  }

  func testUnknownFutureVersionRecoversToDefaultsWithBackup() throws {
    try seed(["version": 99, "settings": ["intervalMinutes": 60]])
    let recovered = try loadedSettings()
    XCTAssertEqual(recovered.intervalMinutes, GKSettingsV1().intervalMinutes)
    try assertBackupExists()
  }

  func testV1DocumentMissingSettingsPayloadRecoversWithBackup() throws {
    try seed(["version": 1])
    let recovered = try loadedSettings()
    XCTAssertEqual(recovered, GKSettingsV1())
    try assertBackupExists()
  }

  func testV1DocumentWithWrongTypedFieldRecoversWithBackup() throws {
    try seed(["version": 1, "settings": ["intervalMinutes": "soon", "allowEsc": true]])
    let recovered = try loadedSettings()
    XCTAssertEqual(recovered, GKSettingsV1())
    try assertBackupExists()
  }

  func testHealthyCurrentFileLoadsWithoutRewriteOrBackup() throws {
    var settings = GKSettingsV1()
    settings.intervalMinutes = 77
    settings.messages = ["Custom reminder"]
    SettingsStore(directory: directory).persist(settings)
    let originalBytes = try Data(contentsOf: settingsURL)

    let loaded = try loadedSettings()
    XCTAssertEqual(loaded.intervalMinutes, 77)
    XCTAssertEqual(loaded.messages, ["Custom reminder"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    XCTAssertEqual(try Data(contentsOf: settingsURL), originalBytes)
  }

  func testV1DocumentWithLegacyWeekdaysOnlyDecodesToWeekdaySet() throws {
    try seed([
      "version": 1,
      "settings": [
        "intervalMinutes": 30,
        "officeHours": [
          "enabled": true,
          "startMinuteOfDay": 540,
          "endMinuteOfDay": 1020,
          "weekdaysOnly": false,
        ],
      ],
    ])
    let migrated = try loadedSettings()
    XCTAssertEqual(migrated.intervalMinutes, 30)
    XCTAssertEqual(migrated.officeHours.days, OfficeHoursSettings.allDays)
  }

  func testMigratingLegacyWeekdaysFileNormalizesWithoutLosingData() throws {
    try seed([
      "version": 1,
      "settings": [
        "intervalMinutes": 30,
        "officeHours": [
          "enabled": true,
          "startMinuteOfDay": 540,
          "endMinuteOfDay": 1020,
          "weekdaysOnly": true,
        ],
      ],
    ])
    let migrated = try loadedSettings()
    XCTAssertEqual(migrated.intervalMinutes, 30)
    XCTAssertEqual(migrated.officeHours.days, OfficeHoursSettings.weekdays)
    try assertBackupExists()
  }

  func testV1DocumentMissingPhase7FieldsDecodesToDefaults() throws {
    try seed([
      "version": 1,
      "settings": ["intervalMinutes": 25],
    ])
    let s = try loadedSettings()
    XCTAssertTrue(s.menuBarCountdown)
    XCTAssertEqual(s.accentChoice, .brand)
    XCTAssertEqual(s.overlayBackground, .blur)
    XCTAssertNil(s.overlayImagePath)
  }

  func testOverlayImagePathRoundTripsAndEmptyClears() throws {
    var s = GKSettingsV1(overlayBackground: .image, overlayImagePath: "/tmp/x.png")
    let encoded = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(GKSettingsV1.self, from: encoded)
    XCTAssertEqual(decoded.overlayBackground, .image)
    XCTAssertEqual(decoded.overlayImagePath, "/tmp/x.png")

    s.overlayImagePath = ""
    XCTAssertNil(s.sanitized().overlayImagePath)
  }

  func testLegacyAppearanceFileFoldsIntoFreshDefaultsAndIsRemoved() throws {
    try seedAppearance(["theme": "ocean", "hasCompletedOnboarding": true])

    let settings = try loadedSettings()
    XCTAssertTrue(settings.hasCompletedOnboarding)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: appearanceURL.path),
      "the legacy file is consumed by the fold")
  }

  func testLegacyAppearanceFileFoldsAlongsideExistingSettings() throws {
    var existing = GKSettingsV1()
    existing.intervalMinutes = 45
    SettingsStore(directory: directory).persist(existing)
    try seedAppearance(["theme": "violet", "hasCompletedOnboarding": true])

    let settings = try loadedSettings()
    XCTAssertEqual(settings.intervalMinutes, 45, "existing settings survive the fold")
    XCTAssertTrue(settings.hasCompletedOnboarding)
  }

  func testLegacyAppearanceFoldRunsOnce() throws {
    try seedAppearance(["theme": "mint", "hasCompletedOnboarding": true])
    _ = try loadedSettings()

    // Second load with no appearance file keeps the folded values.
    let settings = try loadedSettings()
    XCTAssertTrue(settings.hasCompletedOnboarding)
  }

  func testCorruptLegacyAppearanceFileIsRemovedWithoutChangingSettings() throws {
    try Data("not json".utf8).write(to: appearanceURL)

    let settings = try loadedSettings()
    XCTAssertFalse(settings.hasCompletedOnboarding)
    XCTAssertFalse(FileManager.default.fileExists(atPath: appearanceURL.path))
  }

  func testCompletedOnboardingSurvivesExistingSettings() throws {
    var existing = GKSettingsV1()
    existing.intervalMinutes = 45
    SettingsStore(directory: directory).persist(existing)
    try seedAppearance(["hasCompletedOnboarding": true])

    let settings = try loadedSettings()
    XCTAssertEqual(settings.intervalMinutes, 45, "existing settings survive the fold")
    XCTAssertTrue(settings.hasCompletedOnboarding)
  }

  func testStaleThemeKeyIsIgnored() throws {
    // The four-variant theme system is gone; a stale "theme" key must
    // not corrupt the decode.
    var json =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(GKSettingsV1())) as! [String: Any]
    json["theme"] = "ember"
    let decoded = try JSONDecoder().decode(
      GKSettingsV1.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(decoded.intervalMinutes, GKSettingsV1().intervalMinutes)
  }
}

// MARK: - Shortcut bindings

extension SettingsMigrationTests {
  func testDefaultBindingsPreserveTheHardCodedHotkeys() {
    let bindings = GKSettingsV1().shortcuts
    XCTAssertEqual(
      bindings.startBreak,
      ShortcutDescriptor(keyCode: 11, carbonModifiers: 256 | 2048))
    XCTAssertEqual(
      bindings.togglePause,
      ShortcutDescriptor(keyCode: 35, carbonModifiers: 256 | 2048))
    XCTAssertNil(bindings.snoozeBreak)
  }

  func testSettingsWithoutShortcutsFieldDecodeDefaults() throws {
    var json =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(GKSettingsV1()))
      as! [String: Any]
    json.removeValue(forKey: "shortcuts")
    let decoded = try JSONDecoder().decode(
      GKSettingsV1.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(decoded.shortcuts, ShortcutBindings())
  }

  func testClearingABindingRoundTripsAsNil() throws {
    var settings = GKSettingsV1()
    settings.shortcuts[.startBreak] = nil
    settings.shortcuts[.snoozeBreak] = ShortcutDescriptor(
      keyCode: 1, carbonModifiers: 256 | 4096)
    let decoded = try JSONDecoder().decode(
      GKSettingsV1.self, from: JSONEncoder().encode(settings))
    XCTAssertNil(decoded.shortcuts.startBreak)
    XCTAssertEqual(
      decoded.shortcuts.snoozeBreak,
      ShortcutDescriptor(keyCode: 1, carbonModifiers: 256 | 4096))
  }
}
