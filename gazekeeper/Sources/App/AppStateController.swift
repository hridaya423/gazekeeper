import AppKit
import Foundation
import GazeKeeperCore

@MainActor
@Observable
final class AppStateController {
  private(set) var snapshot: SchedulerSnapshot
  /// The instant `snapshot` was taken — the menu-bar label renders
  /// against it, so the wake timer is its only clock.
  private(set) var snapshotDate = Date()
  private(set) var statsRevision: Int = 0
  let clock: OffsetClock
  /// The domain core: scheduler, detectors, and wellness cadence behind one
  /// interface. The controller is the imperative shell — it feeds inputs,
  /// performs the output side effects (log, toasts, chime, overlay),
  /// and re-arms its timer to the engine's nextWakeup.
  let engine: BreakEngine
  private var wakeTimer: DispatchSourceTimer?
  /// Called after every pump so the shell can refresh derived UI (menu title,
  /// popover state) in step with the engine instead of its own timer.
  var onTick: (() -> Void)?
  private var overlayWindow: BreakOverlayCoordinator?
  private let dataDirectory: URL

  /// Where settings.json, the event log, and stats rollups live —
  /// surfaced to Settings → Advanced's "Reveal" button.
  var dataDirectoryURL: URL { dataDirectory }
  private var forceReduceMotion = false
  var frontmostPoller: FrontmostPoller?
  private(set) var nudgeEvents: [SchedulerEvent] = []
  private(set) var eventLog: EventLog
  private(set) var loggedEventCount = 0
  let sessionLifecycle: SessionLifecycleController
  static let maxNudgeEvents = 200

  init(
    settings: GKSettingsV1, clock: OffsetClock, dataDirectory: URL,
    idleProvider: (any GKIdleProviding)? = nil,
    lullProvider: any GKInputLullProviding = ZeroLullProvider(),
    calendarProvider: EKCalendarProvider? = nil
  ) {
    self.clock = clock
    self.dataDirectory = dataDirectory
    #if DEBUG
      self.forceReduceMotion = DataLocations.resolveForceReduceMotion()
    #else
      self.forceReduceMotion = false
    #endif
    self.sessionLifecycle = SessionLifecycleController(clock: clock, terminator: AppTerminator())
    let log = EventLog(directory: dataDirectory)
    log.loadFromDisk()
    self.eventLog = log
    self.engine = BreakEngine(
      settings: settings, clock: clock,
      idleProvider: idleProvider ?? ZeroIdleProvider(),
      priorBreaksStarted: log.entries.filter {
        $0.kind == .breakStarted
      }.count, lullProvider: lullProvider)
    let bootNow = clock.now()
    if log.entries.isEmpty
      || !Calendar.current.isDate(
        log.entries.last?.at ?? bootNow, inSameDayAs: bootNow)
    {
      log.append(LoggedEvent(kind: .sessionStarted, reason: "boot", at: bootNow))
    } else {
      log.append(LoggedEvent(kind: .sessionStarted, reason: "resume", at: bootNow))
    }
    self.loggedEventCount = log.entries.count
    self.calendarProvider = calendarProvider
    if let lastDigest = log.entries.last(where: {
      $0.kind == .nudgeSent && $0.reason == WellnessNudgeKind.digest.rawValue
    })?.at {
      engine.noteDigestDelivered(at: lastDigest)
    }
    self.snapshot = engine.snapshot
    rearmWake()
    self.calendarProvider?.onChange = { [weak self] in
      DispatchQueue.main.async { self?.refreshCalendar() }
    }
    refreshCalendar()
  }

  var currentSettings: GKSettingsV1 {
    engine.currentSettings
  }

  /// Stats recompute over the full append-only log only when the inputs can
  /// change: a new event (loggedEventCount) or a new minute (open dues accrue
  /// overdue per minute). Reads hit the cache on every other call.
  var todayScore: ScreenScore {
    let key = statsCacheKey
    if let cache = todayScoreCache, cache.key == key { return cache.value }
    let value = ScreenScore.score(
      events: eventLog.entries, dayBucket: clock.now(), calendar: .current,
      now: clock.now())
    todayScoreCache = (key, value)
    return value
  }

  /// Cadence fatigue advice for the dashboard card, if the pattern earns
  /// one. Reads the same event log the score does — no extra state.
  var cadenceSuggestion: CadenceSuggestion? {
    CadenceAdvisor.suggest(
      events: eventLog.entries, now: clock.now(), calendar: .current,
      currentIntervalMinutes: currentSettings.intervalMinutes,
      hasLongBreaks: currentSettings.longBreakEvery > 0,
      dismissedKey: currentSettings.dismissedCadenceSuggestion)
  }

  /// Apply the advice: set the new cadence and mark it applied so the
  /// advisor waits for the window to prove the new pattern before
  /// speaking again.
  func applyCadenceSuggestion(_ suggestion: CadenceSuggestion) {
    updateSettings { settings in
      switch suggestion.kind {
      case .longerInterval(let minutes):
        settings.intervalMinutes = minutes
        settings.dismissedCadenceSuggestion = "applied:\(minutes)"
      case .addLongBreaks:
        settings.longBreakEvery = 4
        settings.dismissedCadenceSuggestion = "applied:\(settings.intervalMinutes)"
      }
    }
  }

  func dismissCadenceSuggestion(_ suggestion: CadenceSuggestion) {
    updateSettings { $0.dismissedCadenceSuggestion = suggestion.dismissKey }
  }

  /// Dashboard Export… — hands the live log to the save-panel glue.
  func exportStats(format: StatsExporter.Format) {
    StatsExporter.export(eventLog, format: format)
  }

  var scoreSeries: [DailyScorePoint] {
    let key = statsCacheKey
    if let cache = scoreSeriesCache, cache.key == key { return cache.value }
    let value = ScreenScore.dailySeries(
      events: eventLog.entries, endingAt: clock.now(), days: 30, calendar: .current,
      now: clock.now())
    scoreSeriesCache = (key, value)
    return value
  }

  private var statsCacheKey: Int {
    loggedEventCount &* 61_440 &+ Int(clock.now().timeIntervalSince1970 / 60)
  }

  private var todayScoreCache: (key: Int, value: ScreenScore)?
  private var scoreSeriesCache: (key: Int, value: [DailyScorePoint])?

  /// Serial queue for settings writes; a debounce coalesces rapid edits
  /// (slider drags produce a mutation per tick) into one disk write.
  private let settingsPersistQueue = DispatchQueue(label: "gazekeeper.settings.persist")
  private var pendingSettingsWrite: GKSettingsV1?
  private var pendingSettingsWorkItem: DispatchWorkItem?

  var countdownSeconds: Int {
    Int(max(0, ceil(snapshot.state.effectiveRemaining(from: clock.now()))))
  }

  var breakRemainingRounded: Int {
    guard snapshot.state.phase == .breaking, let end = snapshot.state.breakEndsAt else { return 0 }
    if snapshot.state.isPaused() {
      return Int(max(0, ceil(snapshot.state.pausedRemaining ?? 0)))
    }
    return Int(max(0, ceil(end.timeIntervalSince(snapshotDate))))
  }

  var reduceMotionEffective: Bool {
    forceReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// Reads `snapshotDate`, not the clock: during a break the snapshot
  /// itself stays equal second to second, so the date is the only observed
  /// value that changes and re-renders the countdown.
  var overlayModel: BreakOverlayModel {
    BreakOverlayModel.make(
      state: snapshot.state,
      settings: engine.currentSettings,
      reduceMotion: reduceMotionEffective,
      now: snapshotDate
    )
  }

  static func format(_ totalSeconds: Int) -> String {
    String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }

  func attach(overlayWindow: BreakOverlayCoordinator) {
    self.overlayWindow = overlayWindow
    syncOverlay()
  }

  var isOverlayVisible: Bool {
    overlayWindow?.isVisible ?? false
  }

  var overlayFrame: CGRect? {
    overlayWindow?.frame
  }

  /// The engine's only timed entry point. It runs when `nextWake` said
  /// something could be due — a phase transition, a nudge, or the one-second
  /// boundary a visible countdown cares about — never on a fixed interval.
  func pump() {
    let now = clock.now()
    let output = engine.handle(.tick(now))
    reactToEvents(output.events)
    deliverNudges(output.nudges)
    stateDidChange()
  }

  /// Shared tail for every state change: republish the snapshot, sync the
  /// overlay, tell the shell, and re-arm the single wake timer.
  private func stateDidChange() {
    // Stamp the snapshot after the engine ran, not with the caller's
    // earlier `now`: a break end set a few microseconds later would
    // otherwise round up to one extra second on screen.
    refreshSnapshot(at: clock.now())
    syncOverlay()
    syncPill()
    onTick?()
    rearmWake()
  }

  private func rearmWake() {
    wakeTimer?.cancel()
    wakeTimer = nil
    guard let next = nextWake() else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now() + max(0.05, next.timeIntervalSince(clock.now())),
      leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      Task { @MainActor in self.pump() }
    }
    timer.resume()
    wakeTimer = timer
  }

  /// The earliest moment anything time-driven could need the engine.
  private func nextWake() -> Date? {
    let now = clock.now()
    var candidates: [Date] = []
    if let wakeup = engine.nextWakeup(now: now) {
      candidates.append(wakeup)
    }
    if snapshot.state.phase == .breaking && !snapshot.state.isPaused()
      && !snapshot.state.isAway
    {
      // The overlay's countdown text is the only surface the engine feeds
      // once a second; every other live countdown owns a TimelineView.
      candidates.append(now.addingTimeInterval(1))
    }
    if let boundary = nextMenuBarBoundary(after: now) {
      candidates.append(boundary)
    }
    return candidates.min()
  }

  /// The menu-bar label changes on whole minutes before the due, and on
  /// whole seconds inside the final minute when the countdown text shows.
  private func nextMenuBarBoundary(after now: Date) -> Date? {
    let state = snapshot.state
    guard !state.isPaused(), !state.isAway else { return nil }
    let due = state.phase == .breaking ? (state.breakEndsAt ?? state.nextDue) : state.nextDue
    let remaining = due.timeIntervalSince(now)
    guard remaining > 0 else { return nil }
    let step: TimeInterval =
      remaining <= 60 && engine.currentSettings.menuBarCountdown ? 1 : 60
    let toBoundary = remaining.truncatingRemainder(dividingBy: step)
    return now.addingTimeInterval(toBoundary > 0.05 ? toBoundary : step)
  }

  /// Appends scheduler events to the stats log and plays the UI side effects
  /// they imply. Every code path that produces events goes through here so no
  /// event is ever logged without its side effect, or vice versa.
  private func reactToEvents(_ events: [SchedulerEvent]) {
    for event in events {
      appendLoggedEvent(
        LoggedEvent(kind: event.kind, reason: event.reason, at: event.at))
      switch event.kind {
      case .breakDue:
        break
      case .breakTaken, .breakWorked:
        if engine.currentSettings.soundEnabled { BreakChime.play() }
      default:
        break
      }
    }
  }

  private func deliverNudges(_ nudges: [WellnessNudge]) {
    for nudge in nudges {
      var shown = nudge
      if nudge.kind == .digest {
        // The cadence owns *when*; the body is composed here where the
        // event log lives. An empty last week still logs the send but
        // shows nothing — no toast for an empty story.
        guard
          let body = WeeklyDigest.body(
            events: eventLog.entries, now: clock.now(), calendar: .current)
        else { continue }
        shown = WellnessNudge(kind: .digest, body: body, at: nudge.at)
      }
      toast?.show(shown)
      nudgeEvents.append(
        SchedulerEvent(kind: .nudgeSent, reason: nudge.kind.rawValue, at: nudge.at))
      if nudgeEvents.count > Self.maxNudgeEvents {
        nudgeEvents.removeFirst(nudgeEvents.count - Self.maxNudgeEvents)
      }
    }
  }

  /// The machine went away (sleep, screen-sleep, or lock). The engine
  /// freezes; when it comes back `machineAwayEnded` decides natural-break
  /// vs grace.
  func machineAwayBegan() {
    _ = engine.handle(.awayBegan)
    stateDidChange()
  }

  func machineAwayEnded() {
    let output = engine.handle(.awayEnded)
    reactToEvents(output.events)
    stateDidChange()
  }

  /// Change-driven detector entry point: the poller calls this only when the
  /// frontmost sample actually changed.
  /// Merges the frontmost observation with the hardware signals into
  /// one detector snapshot — the engine sees the whole world at once.
  func handleFrontmostSample(_ sample: FrontmostObservation?) {
    lastFrontmost = sample
    let output = engine.handle(.detectorSignals(currentSignals(frontmost: sample)))
    guard !output.events.isEmpty else { return }
    reactToEvents(output.events)
    stateDidChange()
  }

  /// A hardware signal flipped — re-evaluate with the remembered
  /// frontmost observation.
  func refreshDetectorSignals() {
    handleFrontmostSample(lastFrontmost)
  }

  private func currentSignals(frontmost: FrontmostObservation?) -> DetectorSignals {
    DetectorSignals(
      cameraRunning: cameraSignals?.isRunning ?? false,
      microphoneRunning: microphoneSignals?.isRunning ?? false,
      screenSharing: screenShareSignals.isSharing(),
      fullscreenActive: frontmost?.fullscreen ?? false,
      frontmostBundleId: frontmost?.bundleId)
  }

  func triggerBreakNow(duration: TimeInterval? = nil) {
    reactToEvents(engine.handle(.triggerBreak(duration: duration)).events)
    stateDidChange()
  }

  func appendMenuRevealedEvent(reason: String) {
    reactToEvents(engine.handle(.menuRevealed(reason: reason)).events)
  }

  func skipBreak(reason: String = "user") {
    reactToEvents(engine.handle(.skip(reason: reason)).events)
    if reason == "esc" {
      NSLog("GazeKeeper break skipped via esc")
    }
    stateDidChange()
  }

  #if DEBUG
    func setForceReduceMotion(_ forced: Bool) {
      forceReduceMotion = forced
      refreshSnapshot(at: clock.now())
      syncOverlay()
    }
  #endif

  func completeBreakIfNeeded() {
    reactToEvents(engine.handle(.completeBreak).events)
    stateDidChange()
  }

  func postpone(seconds: TimeInterval, reason: String = "user") {
    reactToEvents(engine.handle(.postpone(seconds: seconds)).events)
    stateDidChange()
  }

  /// Bounded pause for the menu's 30m/1h/until-tomorrow items.
  func pauseFor(minutes: Int) {
    pauseUser(until: clock.now().addingTimeInterval(TimeInterval(minutes * 60)))
  }

  /// "Until tomorrow" — the next local midnight.
  func pauseUntilTomorrow() {
    let now = clock.now()
    let midnight =
      Calendar.current.nextDate(
        after: now, matching: DateComponents(hour: 0), matchingPolicy: .nextTime)
      ?? now.addingTimeInterval(24 * 3600)
    pauseUser(until: midnight)
  }

  /// Bounded pause for the menu's 30m/1h/until-tomorrow items.
  func pauseUser(until deadline: Date) {
    reactToEvents(engine.handle(.pauseUser(until: deadline)).events)
    stateDidChange()
  }

  /// Cancels the upcoming due and re-arms a full interval; a skip during a
  /// pending heads-up resolves that due as an ordinary skip.
  func skipNextBreak() {
    reactToEvents(engine.handle(.skipNextBreak).events)
    stateDidChange()
  }

  func setPaused(
    byUser userPaused: Bool? = nil, byDetector detectorPaused: Bool? = nil,
    byFocus focusPaused: Bool? = nil
  ) {
    reactToEvents(
      engine.handle(
        .setPaused(user: userPaused, detector: detectorPaused, focus: focusPaused)
      )
      .events)
    stateDidChange()
  }

  #if DEBUG
    func fastForward(seconds: TimeInterval) {
      clock.shiftOffset(bySeconds: seconds)
      pump()
    }

    func setClockOffset(seconds: TimeInterval) {
      clock.setOffset(seconds)
      pump()
    }
  #endif

  /// Typed settings writes used by every in-app surface. The mutation is
  /// applied to a copy, normalized once, then committed through the shared
  /// pipeline — no string keys, no untyped values inside the app.
  func updateSettings(_ mutate: (inout GKSettingsV1) -> Void) {
    var updated = engine.currentSettings
    mutate(&updated)
    commitSettings(updated.sanitized())
  }

  #if DEBUG
    /// The untrusted-input boundary for the debug server, which only speaks
    /// strings. Kept for that surface alone; in-app writes go through
    /// `updateSettings`.
    func applySetting(key: String, value: Any?) -> SettingsApplyOutcome {
      var updated = engine.currentSettings
      let outcome = GazeKeeperSettings.apply(key: key, value: value, to: &updated)
      switch outcome {
      case .applied, .clamped:
        commitSettings(updated)
      case .unknownKey, .invalidValue:
        break
      }
      refreshSnapshot(at: clock.now())
      return outcome
    }
  #endif

  private func commitSettings(_ updated: GKSettingsV1) {
    var resolved = updated
    if resolved.launchAtLogin != engine.currentSettings.launchAtLogin {
      LoginItem.setEnabled(resolved.launchAtLogin)
      resolved.launchAtLogin = LoginItem.isEnabled
    }
    let shortcutsChanged = resolved.shortcuts != engine.currentSettings.shortcuts
    engine.handle(.settingsChanged(resolved))
    schedulePersist()
    if shortcutsChanged {
      onShortcutBindingsChanged?(resolved.shortcuts)
    }
    if resolved.calendarAware {
      refreshCalendar()
    }
    stateDidChange()
  }

  private var calendarProvider: EKCalendarProvider?
  /// How far ahead to look for meetings. Pull-forward only touches dues
  /// inside a 2-minute window anyway; a wider horizon just costs an
  /// identical predicate scan.
  private let calendarHorizon: TimeInterval = 4 * 3600

  /// Re-queries the provider and pushes fresh starts into the engine.
  /// No-op while the feature is off or access is denied.
  func refreshCalendar() {
    guard engine.currentSettings.calendarAware, let provider = calendarProvider
    else { return }
    provider.refreshAuthorization()
    let starts = provider.upcomingMeetingStarts(within: calendarHorizon, from: clock.now())
    engine.handle(.calendarChanged(starts: starts))
    // A pull-forward moves nextDue *earlier* — the armed timer must
    // re-target it or the heads-up arrives late.
    stateDidChange()
  }

  var calendarAccessGranted: Bool {
    calendarProvider?.isAuthorized ?? false
  }

  /// TCC request behind the settings toggle. The completion runs on the
  /// main queue; a grant immediately pulls the first meeting set.
  func requestCalendarAccess(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    guard let provider = calendarProvider else {
      completion(false)
      return
    }
    provider.requestAccess { granted in
      DispatchQueue.main.async {
        if granted { self.refreshCalendar() }
        MainActor.assumeIsolated {
          completion(granted)
        }
      }
    }
  }

  /// Brings the stored launch-at-login preference in line with SMAppService at
  /// boot, so toggling the app off in System Settings is honored.
  func reconcileLaunchAtLogin() {
    var updated = engine.currentSettings
    let resolved = LoginItem.reconciledValue(stored: updated.launchAtLogin)
    guard resolved != updated.launchAtLogin else { return }
    updated.launchAtLogin = resolved
    engine.handle(.settingsChanged(updated))
    schedulePersist()
    refreshSnapshot(at: clock.now())
  }

  #if DEBUG
    func injectFrontmostApp(bundleId: String?, title: String?, fullscreen: Bool) {
      frontmostPoller?.inject(
        sample: FrontmostObservation(bundleId: bundleId ?? "", fullscreen: fullscreen))
    }

    func clearFrontmostInject() {
      frontmostPoller?.inject(sample: nil)
    }

    func injectIdle(seconds: TimeInterval) {
      engine.injectIdle(seconds: seconds)
      pump()
    }
  #endif

  var detectorEventEntries: [SchedulerEvent] {
    engine.detectorDecisions.map { decision in
      SchedulerEvent(kind: decision.eventKind, reason: decision.detectorID, at: decision.at)
    }
  }

  struct TrayMenuState: Equatable {
    var phase: GazeKeeperPhase
    var pausedByUser: Bool
    var pausedByAnyGate: Bool
    var overlayVisible: Bool

    var snoozesRemaining: Int
    /// Human-readable detector reason while detector-paused, else nil.
    var detectorPauseReason: String?

    var canStartBreakNow: Bool { !pausedByAnyGate && phase != .breaking }
    var canPostpone: Bool { !pausedByUser }
    var canSkipNextBreak: Bool { !pausedByAnyGate && phase != .breaking }
    var canSnooze: Bool { canPostpone && snoozesRemaining > 0 }

    var pauseActionTitle: String { pausedByUser ? "Resume Scheduling" : "Pause Scheduling" }
  }

  var trayMenuState: TrayMenuState {
    TrayMenuState(
      phase: snapshot.state.phase,
      pausedByUser: snapshot.state.pausedByUser,
      pausedByAnyGate: snapshot.state.isPaused(),
      overlayVisible: isOverlayVisible,
      snoozesRemaining: max(
        0, engine.currentSettings.snoozeLimit - snapshot.state.snoozesUsed),
      detectorPauseReason: detectorPauseReasonText)
  }

  private var detectorPauseReasonText: String? {
    guard let reason = engine.detectorPauseReason else { return nil }
    if case .appRule(let bundleId) = reason {
      let name = NSWorkspace.shared.runningApplications
        .first { $0.bundleIdentifier == bundleId }?.localizedName
      return "\(name ?? bundleId) rule"
    }
    return reason.menuDescription
  }

  private func appendLoggedEvent(_ event: LoggedEvent) {
    eventLog.append(event)
    loggedEventCount += 1
    statsRevision += 1
  }

  func quitAfterFlush() {
    flushPersist()
    endSession(on: eventLog, reason: "quit")
    eventLog.flush()
    NSApp.terminate(nil)
  }

  func applicationWillTerminate() {
    flushPersist()
    endSession(on: eventLog, reason: "quit")
    eventLog.flush()
  }

  /// Onboarding finished: persist the flag and ask for notification
  /// authorization — the heads-up fallback is the app's only system
  /// notification, and this is the one moment a permission prompt makes
  /// sense.
  func completeOnboarding() {
    updateSettings { $0.hasCompletedOnboarding = true }
    notifications.requestAuthorizationIfNeeded()
  }

  func endSession(on log: EventLog, reason: String = "quit") {
    sessionLifecycle.endSession(on: log, reason: reason)
  }

  var pill: PreBreakPill?
  var toast: WellnessToast?
  /// Heads-up fallback for when the pill can't show (fullscreen app owns
  /// the display while the fullscreen detector is off).
  var notifications = NotificationBridge()
  /// The `nextDue` the heads-up notification was last sent for — the
  /// fallback fires once per due, never on every pump.
  private var headsUpNotifiedDue: Date?

  /// Decoded overlay image, cached by path so a break doesn't decode a
  /// multi-megapixel image on the main thread every tick.
  private var overlayImageCache: (path: String, image: NSImage)?

  /// Settings → what actually renders behind the overlay. A missing or
  /// undecodable image falls back to blur rather than a broken backdrop.
  var overlayBackgroundResolved: OverlayBackdrop {
    let settings = engine.currentSettings
    switch settings.overlayBackground {
    case .blur: return .blur
    case .solid: return .solid
    case .image:
      guard let path = settings.overlayImagePath, !path.isEmpty else { return .blur }
      if overlayImageCache?.path == path, let cached = overlayImageCache?.image {
        return .image(cached)
      }
      guard let image = NSImage(contentsOfFile: path) else {
        overlayImageCache = nil
        return .blur
      }
      overlayImageCache = (path, image)
      return .image(image)
    }
  }
  /// Hardware signal providers — their onChange re-evaluates the
  /// detector snapshot through the same frontmost pipe.
  var microphoneSignals: MicrophoneSignalProvider?
  var cameraSignals: CameraSignalProvider?
  let screenShareSignals = ScreenShareProvider()
  private var lastFrontmost: FrontmostObservation?
  /// The shell listens so global hotkeys re-register the moment a
  /// recorded binding lands in settings.
  var onShortcutBindingsChanged: ((ShortcutBindings) -> Void)?

  private func syncPill() {
    let state = snapshot.state
    let suppressed = pillSuppressed(state: state)
    pill?.sync(state: state, suppressed: suppressed)

    let headsUpLive = state.phase == .headsUp && !state.isPaused() && !state.isAway
    if headsUpLive && suppressed {
      if headsUpNotifiedDue != state.nextDue {
        headsUpNotifiedDue = state.nextDue
        notifications.sendHeadsUp(dueIn: state.nextDue.timeIntervalSince(clock.now()))
      }
    } else if headsUpNotifiedDue != nil {
      // Heads-up over (or pill back on screen) — retract the banner.
      headsUpNotifiedDue = nil
      notifications.retractHeadsUp()
    }
  }

  /// A fullscreen app is frontmost while the fullscreen detector is off:
  /// don't float the pill over their content — the notification fallback
  /// covers the heads-up instead. (Detector on ⇒ the engine pauses first,
  /// so the pill never faces this choice.)
  private func pillSuppressed(state: SchedulerState) -> Bool {
    guard lastFrontmost?.fullscreen == true else { return false }
    return engine.currentSettings.detectors["fullscreen"]?.enabled != true
  }

  private func syncOverlay() {
    overlayWindow?.setVisible(snapshot.state.phase == .breaking)
  }

  private func refreshSnapshot(at now: Date) {
    snapshot = engine.snapshot
    snapshotDate = now
  }

  private func schedulePersist() {
    pendingSettingsWrite = engine.currentSettings
    pendingSettingsWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, let pending = self.pendingSettingsWrite else { return }
      self.pendingSettingsWrite = nil
      let directory = self.dataDirectory
      self.settingsPersistQueue.async {
        SettingsStore(directory: directory).persist(pending)
      }
    }
    pendingSettingsWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
  }

  /// Drains the debounce and writes synchronously so no edit can be lost on
  /// the quit path.
  private func flushPersist() {
    pendingSettingsWorkItem?.cancel()
    pendingSettingsWorkItem = nil
    guard let pending = pendingSettingsWrite else { return }
    pendingSettingsWrite = nil
    let directory = dataDirectory
    settingsPersistQueue.sync {
      SettingsStore(directory: directory).persist(pending)
    }
  }
}
