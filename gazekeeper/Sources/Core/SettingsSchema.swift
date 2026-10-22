import Foundation

public struct OfficeHoursSettings: Equatable, Codable, Sendable {
  public static let weekdays: Set<Int> = [2, 3, 4, 5, 6]
  public static let allDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

  private enum CodingKeys: String, CodingKey {
    case enabled
    case startMinuteOfDay
    case endMinuteOfDay
    case days
    case weekdaysOnly
  }

  public var enabled: Bool
  public var startMinuteOfDay: Int
  public var endMinuteOfDay: Int
  public var days: Set<Int>

  public init(
    enabled: Bool = false,
    startMinuteOfDay: Int = 9 * 60,
    endMinuteOfDay: Int = 17 * 60,
    days: Set<Int>? = nil
  ) {
    self.enabled = enabled
    self.startMinuteOfDay = startMinuteOfDay
    self.endMinuteOfDay = endMinuteOfDay
    self.days = days ?? Self.weekdays
  }

  public init(
    enabled: Bool,
    startMinuteOfDay: Int,
    endMinuteOfDay: Int,
    weekdaysOnly: Bool
  ) {
    self.init(
      enabled: enabled,
      startMinuteOfDay: startMinuteOfDay,
      endMinuteOfDay: endMinuteOfDay,
      days: weekdaysOnly ? Self.weekdays : Self.allDays
    )
  }

  public var weekdaysOnly: Bool {
    get { days == Self.weekdays }
    set { days = newValue ? Self.weekdays : Self.allDays }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    startMinuteOfDay =
      try container.decodeIfPresent(Int.self, forKey: .startMinuteOfDay) ?? 9 * 60
    endMinuteOfDay =
      try container.decodeIfPresent(Int.self, forKey: .endMinuteOfDay) ?? 17 * 60
    if let names = try container.decodeIfPresent([String].self, forKey: .days) {
      days = Self.daySet(from: names)
      return
    }
    if let legacyDays = try container.decodeIfPresent(Set<Int>.self, forKey: .days) {
      days = legacyDays.isEmpty ? Self.allDays : legacyDays
      return
    }
    let legacyWeekdaysOnly =
      try container.decodeIfPresent(Bool.self, forKey: .weekdaysOnly) ?? true
    days = legacyWeekdaysOnly ? Self.weekdays : Self.allDays
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(enabled, forKey: .enabled)
    try container.encode(startMinuteOfDay, forKey: .startMinuteOfDay)
    try container.encode(endMinuteOfDay, forKey: .endMinuteOfDay)
    try container.encode(dayNames(), forKey: .days)
  }

  public func dayNames() -> [String] {
    Self.names(forDays: days)
  }

  public static func daySet(from names: [String]) -> Set<Int> {
    let mapped = Set(names.compactMap { weekdayNumber(forName: $0) })
    guard !mapped.isEmpty else { return allDays }
    return mapped
  }

  public static func names(forDays days: Set<Int>) -> [String] {
    dayOrder.filter { days.contains($0) }.compactMap { weekdayName(forNumber: $0) }
  }

  private static let nameByNumber: [Int: String] = [
    1: "sun", 2: "mon", 3: "tue", 4: "wed", 5: "thu", 6: "fri", 7: "sat",
  ]

  private static let numberByName: [String: Int] =
    Dictionary(uniqueKeysWithValues: nameByNumber.map { ($1, $0) })

  private static let dayOrder = [1, 2, 3, 4, 5, 6, 7]

  private static func weekdayNumber(forName raw: String) -> Int? {
    let lowered = raw.lowercased().prefix(3)
    guard lowered.count == 3 else { return nil }
    return numberByName[String(lowered)]
  }

  private static func weekdayName(forNumber number: Int) -> String? {
    nameByNumber[number]
  }
}

public struct WellnessQuietHours: Equatable, Codable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case enabled, startMinuteOfDay, endMinuteOfDay
  }

  public var enabled: Bool
  public var startMinuteOfDay: Int
  public var endMinuteOfDay: Int

  public init(
    enabled: Bool = false,
    startMinuteOfDay: Int = 22 * 60,
    endMinuteOfDay: Int = 8 * 60
  ) {
    self.enabled = enabled
    self.startMinuteOfDay = startMinuteOfDay
    self.endMinuteOfDay = endMinuteOfDay
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    startMinuteOfDay =
      try container.decodeIfPresent(Int.self, forKey: .startMinuteOfDay) ?? 22 * 60
    endMinuteOfDay =
      try container.decodeIfPresent(Int.self, forKey: .endMinuteOfDay) ?? 8 * 60
  }

  public static func clampMinute(_ minute: Int) -> Int {
    GazeKeeperSettings.clamp(minute, to: 0...1440)
  }

  public func suppresses(at date: Date, calendar: Calendar = .current) -> Bool {
    guard enabled else { return false }
    let minute =
      calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    if startMinuteOfDay <= endMinuteOfDay {
      return minute >= startMinuteOfDay && minute < endMinuteOfDay
    }
    return minute >= startMinuteOfDay || minute < endMinuteOfDay
  }

  /// The next instant the quiet window lifts — `endMinuteOfDay` today or
  /// tomorrow depending on whether the wrap-around window already closed
  /// this morning. Nil when disabled.
  public func nextUnsuppressedTime(after date: Date, calendar: Calendar = .current) -> Date? {
    guard enabled else { return nil }
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = endMinuteOfDay / 60
    components.minute = endMinuteOfDay % 60
    guard let todayEnd = calendar.date(from: components) else { return nil }
    if todayEnd > date { return todayEnd }
    return calendar.date(byAdding: .day, value: 1, to: todayEnd)
  }
}

public struct WellnessSettings: Equatable, Codable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case enabled, postureMinutes, blinkMinutes
    case quietHours, postureMessage, blinkMessage
    case weeklyDigest
  }

  public var enabled: Bool
  public var postureMinutes: Int
  public var blinkMinutes: Int
  public var quietHours: WellnessQuietHours
  public var postureMessage: String?
  public var blinkMessage: String?
  /// Opt-in Monday-morning toast summarizing last week's breaks.
  public var weeklyDigest: Bool

  public init(
    enabled: Bool = true,
    postureMinutes: Int = 30,
    blinkMinutes: Int = 5,
    quietHours: WellnessQuietHours = WellnessQuietHours(),
    postureMessage: String? = nil,
    blinkMessage: String? = nil,
    weeklyDigest: Bool = false
  ) {
    self.enabled = enabled
    self.postureMinutes = postureMinutes
    self.blinkMinutes = blinkMinutes
    self.quietHours = quietHours
    self.postureMessage = postureMessage
    self.blinkMessage = blinkMessage
    self.weeklyDigest = weeklyDigest
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    postureMinutes =
      try container.decodeIfPresent(Int.self, forKey: .postureMinutes) ?? 30
    blinkMinutes =
      try container.decodeIfPresent(Int.self, forKey: .blinkMinutes) ?? 5
    quietHours =
      try container.decodeIfPresent(WellnessQuietHours.self, forKey: .quietHours)
      ?? WellnessQuietHours()
    postureMessage =
      try container.decodeIfPresent(String.self, forKey: .postureMessage)
    blinkMessage =
      try container.decodeIfPresent(String.self, forKey: .blinkMessage)
    weeklyDigest =
      try container.decodeIfPresent(Bool.self, forKey: .weeklyDigest) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(enabled, forKey: .enabled)
    try container.encode(postureMinutes, forKey: .postureMinutes)
    try container.encode(blinkMinutes, forKey: .blinkMinutes)
    try container.encode(quietHours, forKey: .quietHours)
    try container.encodeIfPresent(postureMessage, forKey: .postureMessage)
    try container.encodeIfPresent(blinkMessage, forKey: .blinkMessage)
    try container.encode(weeklyDigest, forKey: .weeklyDigest)
  }
}

public struct DetectorSettings: Equatable, Codable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case enabled, sensitivity
  }

  public var enabled: Bool
  public var sensitivity: Double

  public init(enabled: Bool = true, sensitivity: Double = 0.5) {
    self.enabled = enabled
    self.sensitivity = sensitivity
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    sensitivity =
      try container.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 0.5
  }
}

public enum ShortcutAction: String, Codable, Sendable, CaseIterable {
  case startBreak
  case togglePause
  case snoozeBreak
}

/// A global hotkey as Carbon sees it: virtual key code plus the
/// cmdKey/optionKey/controlKey/shiftKey mask. Stored as raw integers so
/// Core stays platform-free; the App layer converts to and from
/// NSEvent.ModifierFlags at the recorder and registrar.
public struct ShortcutDescriptor: Hashable, Codable, Sendable {
  public var keyCode: UInt32
  public var carbonModifiers: UInt32

  public init(keyCode: UInt32, carbonModifiers: UInt32) {
    self.keyCode = keyCode
    self.carbonModifiers = carbonModifiers
  }
}

public struct ShortcutBindings: Equatable, Codable, Sendable {
  /// Carbon virtual key codes and modifier masks — the defaults mirror
  /// what the hard-coded hotkey always was (⌘⌥B = keyCode 11,
  /// cmdKey 256 | optionKey 2048).
  public static let defaultStartBreak = ShortcutDescriptor(
    keyCode: 11, carbonModifiers: 256 | 2048)
  public static let defaultTogglePause = ShortcutDescriptor(
    keyCode: 35, carbonModifiers: 256 | 2048)

  public var startBreak: ShortcutDescriptor?
  public var togglePause: ShortcutDescriptor?
  public var snoozeBreak: ShortcutDescriptor?

  public init(
    startBreak: ShortcutDescriptor? = Self.defaultStartBreak,
    togglePause: ShortcutDescriptor? = Self.defaultTogglePause,
    snoozeBreak: ShortcutDescriptor? = nil
  ) {
    self.startBreak = startBreak
    self.togglePause = togglePause
    self.snoozeBreak = snoozeBreak
  }

  public subscript(action: ShortcutAction) -> ShortcutDescriptor? {
    get {
      switch action {
      case .startBreak: return startBreak
      case .togglePause: return togglePause
      case .snoozeBreak: return snoozeBreak
      }
    }
    set {
      switch action {
      case .startBreak: startBreak = newValue
      case .togglePause: togglePause = newValue
      case .snoozeBreak: snoozeBreak = newValue
      }
    }
  }

  public var boundActions: [(action: ShortcutAction, descriptor: ShortcutDescriptor)] {
    ShortcutAction.allCases.compactMap { action in
      self[action].map { (action, $0) }
    }
  }
}

/// Whether the menu bar mark is the brand teal or the system accent.
public enum AccentChoice: String, Codable, Sendable, CaseIterable {
  case brand
  case system
}

/// What sits behind the break overlay's content.
public enum OverlayBackground: String, Codable, Sendable, CaseIterable {
  case blur
  case solid
  case image
}

public struct GKSettingsV1: Equatable, Codable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case intervalMinutes, breakSeconds, headsUpSeconds, cooldownSeconds
    case officeHours, allowEsc, messages, soundEnabled
    case wellness, detectors, appRules, launchAtLogin
    case naturalBreakIdleMinutes, snoozeLimit
    case longBreakEvery, longBreakSeconds, longMessages
    case hasCompletedOnboarding, shortcuts
    case calendarAware, dismissedCadenceSuggestion
    case menuBarCountdown, accentChoice, overlayBackground, overlayImagePath
  }

  public static let defaultMessages: [String] = [
    "Find something at least six metres away.",
    "Look out of a window. Rest your eyes on the farthest thing.",
    "Blink slowly a few times. Let your focus go soft.",
  ]

  public static let defaultLongMessages: [String] = [
    "A longer break — step away and let your body reset.",
    "Five minutes to move, stretch, and breathe.",
    "Walk somewhere. Your eyes need distance, not pixels.",
  ]

  public var hasCompletedOnboarding: Bool
  public var intervalMinutes: Int
  public var breakSeconds: Int
  public var headsUpSeconds: Int
  public var cooldownSeconds: Int
  public var officeHours: OfficeHoursSettings
  public var allowEsc: Bool
  public var messages: [String]
  public var soundEnabled: Bool
  public var wellness: WellnessSettings
  public var naturalBreakIdleMinutes: Int
  public var snoozeLimit: Int
  public var longBreakEvery: Int
  public var longBreakSeconds: Int
  public var longMessages: [String]
  public var shortcuts: ShortcutBindings
  public var detectors: [String: DetectorSettings]
  /// bundleID → pause|ignore. Explicit user intent; evaluated before
  /// every heuristic.
  public var appRules: [String: AppRuleAction]
  public var launchAtLogin: Bool
  /// Opt-in: pull a due break forward so it never lands in the last two
  /// minutes before a meeting. Only active once calendar access is granted.
  public var calendarAware: Bool
  /// The last cadence advice dismissed or applied — see
  /// `CadenceAdvisor.suggest` for the key format.
  public var dismissedCadenceSuggestion: String?
  /// Shows the countdown as text next to the menu bar ring. The ring
  /// itself always shows.
  public var menuBarCountdown: Bool
  public var accentChoice: AccentChoice
  public var overlayBackground: OverlayBackground
  /// POSIX path of the image behind the overlay when
  /// `overlayBackground == .image`. Nil ⇒ fall back to `.blur`.
  public var overlayImagePath: String?

  public init(
    intervalMinutes: Int = 20,
    breakSeconds: Int = 20,
    headsUpSeconds: Int = 60,
    cooldownSeconds: Int = 30,
    officeHours: OfficeHoursSettings = OfficeHoursSettings(),
    allowEsc: Bool = false,
    messages: [String] = GKSettingsV1.defaultMessages,
    soundEnabled: Bool = true,
    wellness: WellnessSettings = WellnessSettings(),
    naturalBreakIdleMinutes: Int = 1,
    snoozeLimit: Int = 2,
    longBreakEvery: Int = 0,
    longBreakSeconds: Int = 300,
    longMessages: [String] = GKSettingsV1.defaultLongMessages,
    shortcuts: ShortcutBindings = ShortcutBindings(),
    detectors: [String: DetectorSettings] = [
      "camera": DetectorSettings(),
      "microphone": DetectorSettings(),
      "screenSharing": DetectorSettings(),
      "fullscreen": DetectorSettings(),
    ],
    appRules: [String: AppRuleAction] = [:],
    launchAtLogin: Bool = false,
    hasCompletedOnboarding: Bool = false,
    calendarAware: Bool = false,
    dismissedCadenceSuggestion: String? = nil,
    menuBarCountdown: Bool = true,
    accentChoice: AccentChoice = .brand,
    overlayBackground: OverlayBackground = .blur,
    overlayImagePath: String? = nil
  ) {
    self.intervalMinutes = intervalMinutes
    self.breakSeconds = breakSeconds
    self.headsUpSeconds = headsUpSeconds
    self.cooldownSeconds = cooldownSeconds
    self.officeHours = officeHours
    self.allowEsc = allowEsc
    self.messages = messages.isEmpty ? GKSettingsV1.defaultMessages : messages
    self.soundEnabled = soundEnabled
    self.wellness = wellness
    self.naturalBreakIdleMinutes = naturalBreakIdleMinutes
    self.snoozeLimit = snoozeLimit
    self.longBreakEvery = longBreakEvery
    self.longBreakSeconds = longBreakSeconds
    self.longMessages = longMessages.isEmpty ? GKSettingsV1.defaultLongMessages : longMessages
    self.shortcuts = shortcuts
    self.detectors = detectors
    self.appRules = appRules
    self.launchAtLogin = launchAtLogin
    self.hasCompletedOnboarding = hasCompletedOnboarding
    self.calendarAware = calendarAware
    self.dismissedCadenceSuggestion = dismissedCadenceSuggestion
    self.menuBarCountdown = menuBarCountdown
    self.accentChoice = accentChoice
    self.overlayBackground = overlayBackground
    self.overlayImagePath = overlayImagePath
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let base = GKSettingsV1()
    intervalMinutes =
      try container.decodeIfPresent(Int.self, forKey: .intervalMinutes)
      ?? base.intervalMinutes
    breakSeconds =
      try container.decodeIfPresent(Int.self, forKey: .breakSeconds)
      ?? base.breakSeconds
    headsUpSeconds =
      try container.decodeIfPresent(Int.self, forKey: .headsUpSeconds)
      ?? base.headsUpSeconds
    cooldownSeconds =
      try container.decodeIfPresent(Int.self, forKey: .cooldownSeconds)
      ?? base.cooldownSeconds
    officeHours =
      try container.decodeIfPresent(OfficeHoursSettings.self, forKey: .officeHours)
      ?? base.officeHours
    allowEsc = try container.decodeIfPresent(Bool.self, forKey: .allowEsc) ?? base.allowEsc
    messages = try container.decodeIfPresent([String].self, forKey: .messages) ?? base.messages
    if messages.isEmpty { messages = base.messages }
    soundEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .soundEnabled)
      ?? base.soundEnabled
    wellness =
      try container.decodeIfPresent(WellnessSettings.self, forKey: .wellness)
      ?? base.wellness
    detectors =
      try container.decodeIfPresent([String: DetectorSettings].self, forKey: .detectors)
      ?? base.detectors
    // Legacy keys → the signals that actually implement the intent:
    // "meetings" meant don't-break-during-calls (camera + mic), "video"
    // meant fullscreen media.
    if let meetings = detectors.removeValue(forKey: "meetings") {
      detectors["camera"] = detectors["camera"] ?? meetings
      detectors["microphone"] = detectors["microphone"] ?? meetings
    }
    if let video = detectors.removeValue(forKey: "video") {
      detectors["fullscreen"] = detectors["fullscreen"] ?? video
    }
    appRules =
      try container.decodeIfPresent([String: AppRuleAction].self, forKey: .appRules)
      ?? base.appRules
    launchAtLogin =
      try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
      ?? base.launchAtLogin
    naturalBreakIdleMinutes =
      try container.decodeIfPresent(Int.self, forKey: .naturalBreakIdleMinutes)
      ?? base.naturalBreakIdleMinutes
    snoozeLimit =
      try container.decodeIfPresent(Int.self, forKey: .snoozeLimit)
      ?? base.snoozeLimit
    longBreakEvery =
      try container.decodeIfPresent(Int.self, forKey: .longBreakEvery)
      ?? base.longBreakEvery
    longBreakSeconds =
      try container.decodeIfPresent(Int.self, forKey: .longBreakSeconds)
      ?? base.longBreakSeconds
    shortcuts =
      try container.decodeIfPresent(ShortcutBindings.self, forKey: .shortcuts)
      ?? base.shortcuts
    longMessages =
      try container.decodeIfPresent([String].self, forKey: .longMessages)
      ?? base.longMessages
    if longMessages.isEmpty { longMessages = base.longMessages }
    hasCompletedOnboarding =
      try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)
      ?? base.hasCompletedOnboarding
    calendarAware =
      try container.decodeIfPresent(Bool.self, forKey: .calendarAware)
      ?? base.calendarAware
    dismissedCadenceSuggestion =
      try container.decodeIfPresent(String.self, forKey: .dismissedCadenceSuggestion)
      ?? base.dismissedCadenceSuggestion
    menuBarCountdown =
      try container.decodeIfPresent(Bool.self, forKey: .menuBarCountdown)
      ?? base.menuBarCountdown
    accentChoice =
      try container.decodeIfPresent(AccentChoice.self, forKey: .accentChoice)
      ?? base.accentChoice
    overlayBackground =
      try container.decodeIfPresent(OverlayBackground.self, forKey: .overlayBackground)
      ?? base.overlayBackground
    overlayImagePath =
      try container.decodeIfPresent(String.self, forKey: .overlayImagePath)
      ?? base.overlayImagePath
  }

  /// A copy with every bounded field clamped into its product range and the
  /// message list trimmed/capped. This is the single normalization shared by
  /// write paths that already hold typed values; the string-keyed apply keeps
  /// its per-key clamp reports for untrusted input.
  public func sanitized() -> GKSettingsV1 {
    var copy = self
    copy.intervalMinutes = GazeKeeperSettings.clamp(
      intervalMinutes, to: GazeKeeperSettings.intervalRange)
    copy.breakSeconds = GazeKeeperSettings.clamp(
      breakSeconds, to: GazeKeeperSettings.breakRange)
    copy.headsUpSeconds = GazeKeeperSettings.clamp(
      headsUpSeconds, to: GazeKeeperSettings.headsUpRange)
    copy.cooldownSeconds = GazeKeeperSettings.clamp(
      cooldownSeconds, to: GazeKeeperSettings.cooldownRange)
    copy.wellness.postureMinutes = GazeKeeperSettings.clamp(
      wellness.postureMinutes, to: GazeKeeperSettings.postureRange)
    copy.wellness.blinkMinutes = GazeKeeperSettings.clamp(
      wellness.blinkMinutes, to: GazeKeeperSettings.blinkRange)
    copy.naturalBreakIdleMinutes = GazeKeeperSettings.clamp(
      naturalBreakIdleMinutes, to: GazeKeeperSettings.naturalBreakIdleRange)
    copy.snoozeLimit = GazeKeeperSettings.clamp(
      snoozeLimit, to: GazeKeeperSettings.snoozeLimitRange)
    copy.longBreakEvery = GazeKeeperSettings.clamp(
      longBreakEvery, to: GazeKeeperSettings.longBreakEveryRange)
    copy.longBreakSeconds = GazeKeeperSettings.clamp(
      longBreakSeconds, to: GazeKeeperSettings.longBreakSecondsRange)
    copy.longMessages = Array(
      copy.longMessages
        .map { String($0.prefix(GazeKeeperSettings.messageCharacterLimit)) }
        .filter { !$0.isEmpty }
        .prefix(GazeKeeperSettings.maxMessages))
    if copy.longMessages.isEmpty { copy.longMessages = GKSettingsV1.defaultLongMessages }
    for (id, detector) in copy.detectors {
      var clamped = detector
      clamped.sensitivity = min(
        max(detector.sensitivity, GazeKeeperSettings.detectorSensitivityRange.lowerBound),
        GazeKeeperSettings.detectorSensitivityRange.upperBound)
      copy.detectors[id] = clamped
    }
    copy.messages = Array(
      copy.messages
        .map { String($0.prefix(GazeKeeperSettings.messageCharacterLimit)) }
        .filter { !$0.isEmpty }
        .prefix(GazeKeeperSettings.maxMessages))
    if copy.messages.isEmpty { copy.messages = GKSettingsV1.defaultMessages }
    if let path = copy.overlayImagePath, path.isEmpty { copy.overlayImagePath = nil }
    return copy
  }
}

public struct SettingsClampReport: Equatable, Sendable {
  public let key: String
  public let requestedValue: String
  public let appliedValue: String
  public let reason: String

  public init(key: String, requestedValue: String, appliedValue: String, reason: String) {
    self.key = key
    self.requestedValue = requestedValue
    self.appliedValue = appliedValue
    self.reason = reason
  }
}

public enum SettingsApplyOutcome: Equatable, Sendable {
  case applied
  case unknownKey
  case invalidValue(reason: String)
  case clamped(SettingsClampReport)
}

public enum GazeKeeperSettings {

  public static let intervalRange = 1...240
  public static let idleThresholdSeconds = 300
  public static let naturalBreakIdleRange = 1...120
  public static let snoozeLimitRange = 0...10
  public static let longBreakEveryRange = 0...20
  public static let longBreakSecondsRange = 30...3600
  public static let breakRange = 10...600
  public static let headsUpRange = 10...600
  public static let cooldownRange = 0...600
  public static let postureRange = 5...120
  public static let blinkRange = 5...120
  public static let detectorSensitivityRange = 0.0...1.0
  public static let maxMessages = 12
  public static let messageCharacterLimit = 200

  public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
    Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
  }

  public static func apply(
    _ value: Int, to settings: inout GKSettingsV1, keyPath: WritableKeyPath<GKSettingsV1, Int>,
    range: ClosedRange<Int>, name: String
  ) -> SettingsApplyOutcome {
    if !range.contains(value) {
      let original = value
      settings[keyPath: keyPath] = clamp(value, to: range)
      return .clamped(
        SettingsClampReport(
          key: name,
          requestedValue: String(original),
          appliedValue: String(settings[keyPath: keyPath]),
          reason: "value must be between \(range.lowerBound) and \(range.upperBound)"
        )
      )
    }
    settings[keyPath: keyPath] = value
    return .applied
  }

  public static func apply(key: String, value: Any?, to settings: inout GKSettingsV1)
    -> SettingsApplyOutcome
  {
    switch key {
    case "intervalMinutes":
      guard let number = intValue(value) else { return typeFailure(key: key, expected: "integer") }
      return apply(
        number, to: &settings, keyPath: \.intervalMinutes, range: intervalRange, name: key)
    case "breakSeconds":
      guard let number = intValue(value) else { return typeFailure(key: key, expected: "integer") }
      return apply(number, to: &settings, keyPath: \.breakSeconds, range: breakRange, name: key)
    case "headsUpSeconds":
      guard let number = intValue(value) else { return typeFailure(key: key, expected: "integer") }
      return apply(number, to: &settings, keyPath: \.headsUpSeconds, range: headsUpRange, name: key)
    case "cooldownSeconds":
      guard let number = intValue(value) else { return typeFailure(key: key, expected: "integer") }
      return apply(
        number, to: &settings, keyPath: \.cooldownSeconds, range: cooldownRange, name: key)
    case "allowEsc":
      guard let flag = boolValue(value) else { return typeFailure(key: key, expected: "boolean") }
      settings.allowEsc = flag
      return .applied
    case "soundEnabled":
      guard let flag = boolValue(value) else { return typeFailure(key: key, expected: "boolean") }
      settings.soundEnabled = flag
      return .applied
    case "launchAtLogin":
      guard let flag = boolValue(value) else { return typeFailure(key: key, expected: "boolean") }
      settings.launchAtLogin = flag
      return .applied
    case "messages":
      guard let list = value as? [Any], !list.isEmpty else {
        return .invalidValue(reason: "messages must be a non-empty array of strings")
      }
      let candidates = list.compactMap { $0 as? String }
      guard candidates.count == list.count else {
        return .invalidValue(reason: "messages must contain only strings")
      }
      let trimmed = candidates.map { String($0.prefix(messageCharacterLimit)) }.filter {
        !$0.isEmpty
      }
      guard !trimmed.isEmpty else {
        return .invalidValue(reason: "messages must include at least one non-empty string")
      }
      settings.messages = Array(trimmed.prefix(maxMessages))
      return .applied
    case "officeHours.enabled", "officeHours.start", "officeHours.end", "officeHours.weekdaysOnly",
      "officeHours.days",
      "wellness.enabled", "wellness.postureMinutes", "wellness.blinkMinutes",
      "wellness.quietHours.enabled", "wellness.quietHours.start", "wellness.quietHours.end",
      "wellness.postureMessage", "wellness.blinkMessage",
      "detectors.camera.enabled", "detectors.microphone.enabled",
      "detectors.screenSharing.enabled", "detectors.fullscreen.enabled",
      "detectors.camera.sensitivity", "detectors.microphone.sensitivity",
      "detectors.screenSharing.sensitivity", "detectors.fullscreen.sensitivity":
      return applyNested(key: key, value: value, to: &settings)
    default:
      return .unknownKey
    }
  }

  private static func applyNested(key: String, value: Any?, to settings: inout GKSettingsV1)
    -> SettingsApplyOutcome
  {
    switch key {
    case "officeHours.enabled":
      guard let flag = boolValue(value) else { return typeFailure(key: key, expected: "boolean") }
      settings.officeHours.enabled = flag
      return .applied
    case "officeHours.weekdaysOnly":
      guard let flag = boolValue(value) else { return typeFailure(key: key, expected: "boolean") }
      settings.officeHours.weekdaysOnly = flag
      return .applied
    case "officeHours.days":
      guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else {
        return .invalidValue(reason: "officeHours.days expects an array of weekday names")
      }
      let names = list.compactMap { $0 as? String }.map { String($0.lowercased().prefix(3)) }
      let known = Set(names).intersection(["sun", "mon", "tue", "wed", "thu", "fri", "sat"])
      guard known.count == Set(names).count else {
        return .invalidValue(
          reason: "officeHours.days expects weekday names (sun mon tue wed thu fri sat)"
        )
      }
      settings.officeHours.days = OfficeHoursSettings.daySet(from: names)
      return .applied
    case "officeHours.start":
      guard let minutes = minuteOfDay(value) else {
        return typeFailure(key: key, expected: "minute-of-day integer or HH:MM string")
      }
      settings.officeHours.startMinuteOfDay = minutes
      return .applied
    case "officeHours.end":
      guard let minutes = minuteOfDay(value) else {
        return typeFailure(key: key, expected: "minute-of-day integer or HH:MM string")
      }
      settings.officeHours.endMinuteOfDay = minutes
      return .applied

    case "wellness.enabled":
      guard let flag = boolValue(value) else { return typeFailure(key: key, expected: "boolean") }
      settings.wellness.enabled = flag
      return .applied
    case "wellness.postureMinutes":
      guard let number = intValue(value) else { return typeFailure(key: key, expected: "integer") }
      if !postureRange.contains(number) {
        let original = number
        settings.wellness.postureMinutes = clamp(number, to: postureRange)
        return .clamped(
          SettingsClampReport(
            key: key,
            requestedValue: String(original),
            appliedValue: String(settings.wellness.postureMinutes),
            reason:
              "value must be between \(postureRange.lowerBound) and \(postureRange.upperBound)"
          )
        )
      }
      settings.wellness.postureMinutes = number
      return .applied
    case "wellness.blinkMinutes":
      guard let number = intValue(value) else { return typeFailure(key: key, expected: "integer") }
      if !blinkRange.contains(number) {
        let original = number
        settings.wellness.blinkMinutes = clamp(number, to: blinkRange)
        return .clamped(
          SettingsClampReport(
            key: key,
            requestedValue: String(original),
            appliedValue: String(settings.wellness.blinkMinutes),
            reason: "value must be between \(blinkRange.lowerBound) and \(blinkRange.upperBound)"
          )
        )
      }
      settings.wellness.blinkMinutes = number
      return .applied
    case "detectors.camera.enabled":
      return applyDetectorFlag(value, to: &settings, detectorID: "camera")
    case "detectors.microphone.enabled":
      return applyDetectorFlag(value, to: &settings, detectorID: "microphone")
    case "detectors.screenSharing.enabled":
      return applyDetectorFlag(value, to: &settings, detectorID: "screenSharing")
    case "detectors.fullscreen.enabled":
      return applyDetectorFlag(value, to: &settings, detectorID: "fullscreen")
    case "detectors.camera.sensitivity":
      return applyDetectorSensitivity(value, to: &settings, detectorID: "camera")
    case "detectors.microphone.sensitivity":
      return applyDetectorSensitivity(value, to: &settings, detectorID: "microphone")
    case "detectors.screenSharing.sensitivity":
      return applyDetectorSensitivity(value, to: &settings, detectorID: "screenSharing")
    case "detectors.fullscreen.sensitivity":
      return applyDetectorSensitivity(value, to: &settings, detectorID: "fullscreen")
    case "wellness.quietHours.enabled":
      guard let flag = boolValue(value) else {
        return typeFailure(key: key, expected: "boolean")
      }
      settings.wellness.quietHours.enabled = flag
      return .applied
    case "wellness.quietHours.start":
      return applyQuietHourMinute(value, to: &settings, key: key, at: \.quietHours.startMinuteOfDay)
    case "wellness.quietHours.end":
      return applyQuietHourMinute(value, to: &settings, key: key, at: \.quietHours.endMinuteOfDay)
    case "wellness.postureMessage":
      return applyWellnessMessage(value, to: &settings, key: key) {
        $0.wellness.postureMessage = $1
      }
    case "wellness.blinkMessage":
      return applyWellnessMessage(value, to: &settings, key: key) {
        $0.wellness.blinkMessage = $1
      }
    default:
      return .unknownKey
    }
  }

  private static func applyQuietHourMinute(
    _ value: Any?, to settings: inout GKSettingsV1, key: String,
    at keyPath: WritableKeyPath<WellnessSettings, Int>
  ) -> SettingsApplyOutcome {
    guard let minutes = minuteOfDay(value) else {
      return typeFailure(key: key, expected: "minute-of-day integer or HH:MM string")
    }
    var wellness = settings.wellness
    defer { settings.wellness = wellness }
    if !(0...1440).contains(minutes) {
      let applied = WellnessQuietHours.clampMinute(minutes)
      wellness[keyPath: keyPath] = applied
      return .clamped(
        SettingsClampReport(
          key: key,
          requestedValue: String(minutes),
          appliedValue: String(applied),
          reason: "value must be between 0 and 1440"
        )
      )
    }
    wellness[keyPath: keyPath] = minutes
    return .applied
  }

  private static func applyWellnessMessage(
    _ value: Any?, to settings: inout GKSettingsV1, key: String,
    assign: (inout GKSettingsV1, String?) -> Void
  ) -> SettingsApplyOutcome {
    if value == nil || value is NSNull {
      assign(&settings, nil)
      return .applied
    }
    guard let text = value as? String else {
      return typeFailure(key: key, expected: "string or null")
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      assign(&settings, nil)
      return .applied
    }
    assign(&settings, String(trimmed.prefix(messageCharacterLimit)))
    return .applied
  }

  private static func applyDetectorFlag(
    _ value: Any?, to settings: inout GKSettingsV1, detectorID: String
  ) -> SettingsApplyOutcome {
    guard let flag = boolValue(value) else {
      return typeFailure(key: "detectors.\(detectorID).enabled", expected: "boolean")
    }
    var detector = settings.detectors[detectorID] ?? DetectorSettings()
    detector.enabled = flag
    settings.detectors[detectorID] = detector
    return .applied
  }

  private static func applyDetectorSensitivity(
    _ value: Any?, to settings: inout GKSettingsV1, detectorID: String
  ) -> SettingsApplyOutcome {
    guard let raw = doubleValue(value) else {
      return typeFailure(
        key: "detectors.\(detectorID).sensitivity", expected: "number between 0 and 1")
    }
    let bounded = Double(detectorSensitivityRange.clamp(raw))
    var detector = settings.detectors[detectorID] ?? DetectorSettings()
    if bounded != raw {
      detector.sensitivity = bounded
      settings.detectors[detectorID] = detector
      return .clamped(
        SettingsClampReport(
          key: "detectors.\(detectorID).sensitivity",
          requestedValue: String(describing: raw),
          appliedValue: String(describing: bounded),
          reason: "value must be between 0 and 1"
        )
      )
    }
    detector.sensitivity = bounded
    settings.detectors[detectorID] = detector
    return .applied
  }

  private static func minuteOfDay(_ value: Any?) -> Int? {
    if let number = intValue(value) {
      return (0...1440).contains(number) ? number : nil
    }
    guard let text = value as? String else { return nil }
    let parts = text.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, parts[0] >= 0, parts[0] <= 24, parts[1] >= 0, parts[1] < 60 else {
      return nil
    }
    let total = parts[0] * 60 + parts[1]
    guard (0...1440).contains(total) else { return nil }
    return total
  }

  private static func intValue(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else {
      guard let text = value as? String else { return nil }
      guard !text.contains(".") else { return nil }
      return Int(text)
    }
    switch String(cString: number.objCType) {
    case "B":
      return nil
    case "c":
      let raw = number.intValue
      return raw == 0 || raw == 1 ? nil : raw
    case "d", "f":
      let raw = number.doubleValue
      guard let exact = Int(exactly: raw), raw != 0, raw != 1 else { return nil }
      return exact
    default:
      return number.intValue
    }
  }

  private static func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let number as Double:
      return number
    case let number as NSNumber:
      return number.doubleValue
    case let text as String:
      return Double(text)
    default:
      return nil
    }
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let flag as Bool:
      return flag
    case let number as NSNumber:
      return number.boolValue
    case let text as String?:
      guard let text else { return nil }
      switch text.lowercased() {
      case "true", "yes", "1":
        return true
      case "false", "no", "0":
        return false
      default:
        return nil
      }
    default:
      return nil
    }
  }

  private static func typeFailure(key: String, expected: String) -> SettingsApplyOutcome {
    .invalidValue(reason: "\(key) expects \(expected)")
  }
}

extension ClosedRange where Bound == Double {
  fileprivate func clamp(_ value: Double) -> Double {
    Swift.min(Swift.max(value, lowerBound), upperBound)
  }
}
