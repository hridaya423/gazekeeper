import Foundation

/// Everything the detector layer can know about the world at one
/// instant. Providers in the App layer gather the signals; the engine
/// stays a pure function of this snapshot so every rule is testable.
public struct DetectorSignals: Equatable, Sendable {
  /// A CoreMediaIO video device is running (a real call, not Zoom
  /// sitting open).
  public var cameraRunning = false
  /// The default CoreAudio input device is running.
  public var microphoneRunning = false
  /// A system screen-sharing/recording session is observable.
  public var screenSharing = false
  /// The frontmost app's main window covers (nearly) its own screen's
  /// frame — evaluated by the poller only while a break is near.
  public var fullscreenActive = false
  /// Bundle id of the frontmost app, for user rules.
  public var frontmostBundleId: String?

  public init(
    cameraRunning: Bool = false,
    microphoneRunning: Bool = false,
    screenSharing: Bool = false,
    fullscreenActive: Bool = false,
    frontmostBundleId: String? = nil
  ) {
    self.cameraRunning = cameraRunning
    self.microphoneRunning = microphoneRunning
    self.screenSharing = screenSharing
    self.fullscreenActive = fullscreenActive
    self.frontmostBundleId = frontmostBundleId
  }
}

/// Why the schedule is paused — always explainable, always persisted
/// with the detector events it produced.
public enum DetectorReason: Equatable, Sendable {
  case camera
  case microphone
  case screenSharing
  case fullscreen
  case appRule(String)

  /// The `detectors` settings key that gates this signal.
  public var settingsKey: String {
    switch self {
    case .camera: return "camera"
    case .microphone: return "microphone"
    case .screenSharing: return "screenSharing"
    case .fullscreen: return "fullscreen"
    case .appRule: return "appRules"
    }
  }

  /// Persisted in `detector_paused`/`detector_resumed` event reasons.
  public var eventReason: String {
    switch self {
    case .camera: return "camera"
    case .microphone: return "microphone"
    case .screenSharing: return "screen_sharing"
    case .fullscreen: return "fullscreen"
    case .appRule(let bundleId): return "app_rule:\(bundleId)"
    }
  }

  /// One line for the menu: "Paused — camera in use".
  public var menuDescription: String {
    switch self {
    case .camera: return "camera in use"
    case .microphone: return "microphone in use"
    case .screenSharing: return "screen being shared"
    case .fullscreen: return "fullscreen content"
    case .appRule(let bundleId): return bundleId
    }
  }
}

/// A user-authored rule for one bundle id: `pause` pauses while the app
/// is frontmost; `ignore` exempts the app from app-level heuristics
/// (app rules and the fullscreen check — hardware signals still apply,
/// they observe devices rather than the app).
public enum AppRuleAction: String, Equatable, Codable, Sendable {
  case pause
  case ignore
}

public enum DetectorAction: Equatable, Sendable {
  case paused
  case resumed
}

public struct DetectorDecision: Equatable, Sendable {
  public let detectorID: String
  public let reason: DetectorReason
  public let action: DetectorAction
  public let at: Date

  public init(detectorID: String, reason: DetectorReason, action: DetectorAction, at: Date) {
    self.detectorID = detectorID
    self.reason = reason
    self.action = action
    self.at = at
  }

  public var eventKind: BreakEventKind {
    switch action {
    case .paused:
      return .detectorPaused
    case .resumed:
      return .detectorResumed
    }
  }
}

public final class DetectorEngine {

  private var settings: GKSettingsV1
  /// The reason currently holding the pause, if any. Hardware signals
  /// are already debounced at the device layer, so no streak logic —
  /// an asserted signal means what it says.
  private var activeReason: DetectorReason?

  public init(settings: GKSettingsV1) {
    self.settings = settings
  }

  /// The reason to surface in the menu while paused, or nil.
  public var currentReason: DetectorReason? {
    return activeReason
  }

  public func updateSettings(_ newSettings: GKSettingsV1) {
    settings = newSettings
  }

  /// Evaluates one snapshot and returns a decision only on pause/resume
  /// edges. While paused, `activeReason` tracks the strongest live
  /// signal so the explanation always matches reality; the resume
  /// decision reports the last live reason.
  public func process(signals: DetectorSignals, at now: Date) -> DetectorDecision? {
    let candidate = pickReason(signals)
    switch (activeReason, candidate) {
    case (nil, .some(let reason)):
      activeReason = reason
      return DetectorDecision(
        detectorID: reason.settingsKey, reason: reason, action: .paused, at: now)
    case (.some(let reason), .none):
      activeReason = nil
      return DetectorDecision(
        detectorID: reason.settingsKey, reason: reason, action: .resumed, at: now)
    case (.some, .some(let reason)):
      // Still paused; keep the explanation pointed at what's live now.
      activeReason = reason
      return nil
    case (nil, .none):
      return nil
    }
  }

  /// Reason priority: an explicit user rule beats every heuristic;
  /// hardware signals beat the shape-of-window guesses.
  private func pickReason(_ signals: DetectorSignals) -> DetectorReason? {
    if let bundleId = signals.frontmostBundleId,
      settings.appRules[bundleId] == .pause
    {
      return .appRule(bundleId)
    }
    if enabled(.camera), signals.cameraRunning { return .camera }
    if enabled(.microphone), signals.microphoneRunning { return .microphone }
    if enabled(.screenSharing), signals.screenSharing { return .screenSharing }
    let frontmostIgnored =
      signals.frontmostBundleId.map { settings.appRules[$0] == .ignore } ?? false
    if !frontmostIgnored, enabled(.fullscreen), signals.fullscreenActive {
      return .fullscreen
    }
    return nil
  }

  private func enabled(_ reason: DetectorReason) -> Bool {
    settings.detectors[reason.settingsKey]?.enabled ?? false
  }
}
