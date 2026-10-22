import AppKit
import GazeKeeperCore

/// What the frontmost app looks like right now — a bundle id, and
/// whether its main window covers its own screen. Fullscreen is only
/// computed when `fullscreenGate` says a break is near; otherwise the
/// field stays false so an idle window never trips the detector.
struct FrontmostObservation: Equatable, Sendable {
  var bundleId: String
  var fullscreen: Bool
}

protocol FrontmostObserving: AnyObject {
  var latestSample: FrontmostObservation? { get }
  func start()
  func stop()
}

final class FrontmostPoller: FrontmostObserving, @unchecked Sendable {

  private static let pollInterval: TimeInterval = 2.0

  private let queue = DispatchQueue(
    label: "com.hridya.gazekeeper.frontmost-poller", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private var activationObserver: NSObjectProtocol?
  private let lock = NSLock()
  #if DEBUG
    private var injectedSample: FrontmostObservation?
  #endif

  /// Fires on the poller queue only when the frontmost sample actually
  /// changes — the detector pipeline is change-driven, not interval-driven.
  var onSample: ((FrontmostObservation?) -> Void)?

  /// Checked before every fullscreen computation — the expensive
  /// window-frame evaluation only runs while a break is near.
  var fullscreenGate: (() -> Bool)?

  private(set) var latestSample: FrontmostObservation?

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.setEventHandler { [weak self] in
      self?.pollOnce()
    }
    timer.schedule(
      deadline: .now(), repeating: Self.pollInterval,
      leeway: DispatchTimeInterval.milliseconds(200))
    timer.resume()
    self.timer = timer

    // Activation notifications give instant sampling on app switches;
    // the interval poll above only covers same-app title/fullscreen drift.
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil, queue: nil
    ) { [weak self] _ in
      self?.queue.async { [weak self] in
        self?.pollOnce()
      }
    }
  }

  deinit {
    stop()
  }

  func stop() {
    lock.lock()
    timer?.cancel()
    timer = nil
    if let observer = activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      activationObserver = nil
    }
    lock.unlock()
  }

  #if DEBUG
    func inject(sample: FrontmostObservation?) {
      lock.lock()
      injectedSample = sample
      lock.unlock()
      pollOnce()
    }
  #endif

  func pollOnce() {
    #if DEBUG
      if let injected = currentInjectedSample() {
        setLatest(injected)
        return
      }
    #endif
    setLatest(currentFrontmostObservation())
  }

  #if DEBUG
    private func currentInjectedSample() -> FrontmostObservation? {
      lock.lock()
      defer { lock.unlock() }
      return injectedSample
    }
  #endif

  private func setLatest(_ sample: FrontmostObservation?) {
    lock.lock()
    let changed = latestSample != sample
    if changed { latestSample = sample }
    lock.unlock()
    guard changed else { return }
    onSample?(sample)
  }

  private func currentFrontmostObservation() -> FrontmostObservation? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let gated = fullscreenGate?() ?? false
    return FrontmostObservation(
      bundleId: app.bundleIdentifier ?? "",
      fullscreen: gated && Self.isWindowFullscreen(pid: app.processIdentifier))
  }

  private static func windowList(for pid: pid_t) -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return raw.filter { window in
      guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber else { return false }
      return owner.int32Value == pid
    }
  }

  static func isWindowFullscreen(pid: pid_t) -> Bool {
    windowList(for: pid).contains { window in
      guard let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
        let bounds = window[kCGWindowBounds as String] as? [String: NSNumber]
      else { return false }
      let width = bounds["Width"]?.doubleValue ?? 0
      let height = bounds["Height"]?.doubleValue ?? 0
      guard width > 0, height > 0 else { return false }
      let windowArea = width * height
      return NSScreen.screens.contains { screen in
        let screenFrame = screen.frame
        let intersection = NSIntersectionRect(
          screenFrame,
          NSRect(
            x: bounds["X"]?.doubleValue ?? 0,
            y: bounds["Y"]?.doubleValue ?? 0,
            width: width, height: height))
        // The window lives mostly on this screen and covers ~all of it.
        guard intersection.width * intersection.height >= windowArea * 0.5
        else { return false }
        return intersection.width * intersection.height
          >= screenFrame.width * screenFrame.height * 0.9
      }
    }
  }
}
