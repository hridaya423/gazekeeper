import Foundation

public struct VersionedSettings: Equatable, Codable, Sendable {
  public var version: Int
  public var settings: GKSettingsV1

  public init(version: Int, settings: GKSettingsV1) {
    self.version = version
    self.settings = settings
  }
}

public enum SettingsMigrationError: Error, Equatable {
  case unsupportedVersion(Int)
}

public enum SettingsMigrator {

  public static let currentVersion = 1

  public typealias MigrationStep = @Sendable ([String: Any]) -> [String: Any]

  public static let orderedSteps: [MigrationStep] = [migrateV0ToV1]

  private static func rawVersion(in document: [String: Any]) -> Int? {
    guard let raw = document["version"] else { return nil }
    if let number = raw as? NSNumber { return number.intValue }
    if let text = raw as? String { return Int(text) }
    return nil
  }

  public static func migrate(_ document: [String: Any]) throws -> VersionedSettings {
    var version = rawVersion(in: document) ?? 0
    guard version >= 0, version <= currentVersion else {
      throw SettingsMigrationError.unsupportedVersion(max(version, -1))
    }
    var payload = document
    while version < currentVersion {
      payload = orderedSteps[version](payload)
      version += 1
    }
    guard let settings = decodeSettings(payload) else {
      throw SettingsMigrationError.unsupportedVersion(currentVersion)
    }
    return VersionedSettings(version: currentVersion, settings: settings)
  }

  public static func migrateV0ToV1(_ document: [String: Any]) -> [String: Any] {
    var settings = GKSettingsV1()
    let nested = document["settings"] as? [String: Any]
    for (key, value) in nested ?? document
    where key != "version" && key != "settings" {
      _ = GazeKeeperSettings.apply(key: key, value: value, to: &settings)
    }
    return ["version": currentVersion, "settings": canonicalPayload(for: settings)]
  }

  private static func canonicalPayload(for settings: GKSettingsV1) -> [String: Any] {
    guard
      let encoded = try? JSONEncoder().encode(settings),
      let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    else { return [:] }
    return object
  }

  private static func decodeSettings(_ document: [String: Any]) -> GKSettingsV1? {
    guard let payload = document["settings"] as? [String: Any] else { return nil }
    do {
      let data = try JSONSerialization.data(withJSONObject: payload)
      return try JSONDecoder().decode(GKSettingsV1.self, from: data)
    } catch {
      return nil
    }
  }
}

public struct SettingsStore {

  private let directory: URL
  private let fileManager: FileManager

  public init(directory: URL, fileManager: FileManager = .default) {
    self.directory = directory
    self.fileManager = fileManager
  }

  public var settingsFileURL: URL {
    directory.appendingPathComponent("settings.json")
  }

  public var backupFileURL: URL {
    directory.appendingPathComponent("settings.backup.json")
  }

  @discardableResult
  public func load(defaults: GKSettingsV1 = GKSettingsV1()) -> Result<GKSettingsV1, Error> {
    createDirectoryIfNeeded()
    let url = settingsFileURL
    guard let data = try? Data(contentsOf: url) else {
      var settings = defaults
      foldLegacyAppearance(into: &settings)
      persist(settings)
      return .success(settings)
    }
    do {
      let object = try JSONSerialization.jsonObject(with: data)
      guard let document = object as? [String: Any] else {
        throw SettingsMigrationError.unsupportedVersion(0)
      }
      var settings = try SettingsMigrator.migrate(document).settings
      foldLegacyAppearance(into: &settings)
      if !isSemanticallyCurrent(settings, rawData: data) {
        backupOriginal(data)
        persist(settings)
      }
      return .success(settings)
    } catch {
      backupOriginal(data)
      var settings = defaults
      foldLegacyAppearance(into: &settings)
      persist(settings)
      return .success(settings)
    }
  }

  public func persist(_ settings: GKSettingsV1) {
    createDirectoryIfNeeded()
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let versioned = VersionedSettings(
        version: SettingsMigrator.currentVersion, settings: settings)
      let data = try encoder.encode(versioned)
      try data.write(to: settingsFileURL, options: .atomic)
    } catch {
      NSLog("GazeKeeper failed to persist settings: \(error)")
    }
  }

  private func isSemanticallyCurrent(_ settings: GKSettingsV1, rawData: Data) -> Bool {
    guard
      let object = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
      (object["version"] as? NSNumber)?.intValue == SettingsMigrator.currentVersion,
      let payload = object["settings"] as? [String: Any]
    else { return false }
    guard
      let encoded = try? JSONEncoder().encode(settings),
      let canonical = try? JSONSerialization.jsonObject(with: encoded) as? [AnyHashable: Any]
    else { return false }
    return NSDictionary(dictionary: payload).isEqual(to: canonical)
  }

  /// One-time fold of the retired appearance.json into settings: its
  /// values are the user's actual last choices so a stored theme wins and
  /// onboarding stays completed once completed. The file is removed
  /// afterwards so the fold runs once.
  private func foldLegacyAppearance(into settings: inout GKSettingsV1) {
    let url = directory.appendingPathComponent("appearance.json")
    guard let data = try? Data(contentsOf: url) else { return }
    struct LegacyAppearance: Decodable {
      let hasCompletedOnboarding: Bool?
    }
    if let legacy = try? JSONDecoder().decode(LegacyAppearance.self, from: data),
      legacy.hasCompletedOnboarding == true
    {
      settings.hasCompletedOnboarding = true
    }
    try? fileManager.removeItem(at: url)
  }

  private func backupOriginal(_ data: Data) {
    try? data.write(to: backupFileURL, options: .atomic)
  }

  private func createDirectoryIfNeeded() {
    if !fileManager.fileExists(atPath: directory.path) {
      try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }
}
