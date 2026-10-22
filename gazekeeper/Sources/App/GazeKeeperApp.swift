import AppKit
import GazeKeeperCore
import Sparkle
import SwiftUI

@main
struct GazeKeeperApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      MenuBarController()
        .environment(appDelegate)
        .optionalEnvironmentObject(appDelegate.appearance)
    } label: {
      MenuBarLabel()
        .environment(appDelegate)
        .optionalEnvironmentObject(appDelegate.appearance)
        .accessibilityIdentifier("gk-menubar-extra-icon")
    }
    .menuBarExtraStyle(.window)
  }
}

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {

  static var shared: AppDelegate?

  private(set) var trayMenuState = AppStateController.TrayMenuState(
    phase: .idle, pausedByUser: false, pausedByAnyGate: false, overlayVisible: false,
    snoozesRemaining: 0)

  private(set) var controller: AppStateController?
  private(set) var appearance: AppearanceModel?
  private var overlay: BreakOverlayCoordinator?
  #if DEBUG
    private var debugServer: DebugServer?
  #endif
  private var singleInstance: SingleInstanceCoordinator?
  private var updaterController: SPUStandardUpdaterController?
  @ObservationIgnored private nonisolated(unsafe) var awayObservers: [NSObjectProtocol] = []

  override init() {
    super.init()
    Self.shared = self
  }

  /// Surfaces that read the delegate (the menu popover) render against a
  /// live controller in snapshot tests without launching the app.
  convenience init(controller: AppStateController) {
    self.init()
    self.controller = controller
    trayMenuState = controller.trayMenuState
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }

  deinit {
    for token in awayObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
  }

  /// Sleep, screen-sleep, and session lock all mean "the user stepped
  /// away". Folded into one pair of engine inputs; overlapping begins are
  /// harmless (the first timestamp wins).
  private func installAwayObservers(on controller: AppStateController) {
    let center = NSWorkspace.shared.notificationCenter
    let began: [Notification.Name] = [
      NSWorkspace.willSleepNotification,
      NSWorkspace.screensDidSleepNotification,
      NSWorkspace.sessionDidResignActiveNotification,
    ]
    let ended: [Notification.Name] = [
      NSWorkspace.didWakeNotification,
      NSWorkspace.screensDidWakeNotification,
      NSWorkspace.sessionDidBecomeActiveNotification,
    ]
    for name in began {
      awayObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
          Task { @MainActor in controller.machineAwayBegan() }
        })
    }
    for name in ended {
      awayObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
          Task { @MainActor in controller.machineAwayEnded() }
        })
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let dataDirectory = DataLocations.resolveDataDirectory()

    // Claim the single instance before booting anything that writes state:
    // a second launch must exit without touching the stats log or settings.
    let coordinator = SingleInstanceCoordinator(
      appDelegate: self,
      lockURL: dataDirectory.appendingPathComponent("instance.lock"))
    self.singleInstance = coordinator
    guard coordinator.claimPrimaryInstance() else {
      NSApp.terminate(nil)
      return
    }

    let store = SettingsStore(directory: dataDirectory)
    let settings: GKSettingsV1
    if case .success(let loaded) = store.load() {
      settings = loaded
    } else {
      settings = GKSettingsV1()
    }

    let clock = OffsetClock()
    let controller = AppStateController(
      settings: settings, clock: clock, dataDirectory: dataDirectory,
      idleProvider: CGIdleProvider(), lullProvider: CGEventLullProvider(),
      calendarProvider: EKCalendarProvider())
    self.controller = controller
    controller.reconcileLaunchAtLogin()
    installAwayObservers(on: controller)

    let appearance = AppearanceModel(controller: controller)
    self.appearance = appearance
    if !appearance.hasCompletedOnboarding {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.openWelcomeWindow()
      }
    }

    let poller = FrontmostPoller()
    poller.onSample = { [weak controller] sample in
      Task { @MainActor in controller?.handleFrontmostSample(sample) }
    }
    controller.frontmostPoller = poller
    poller.start()
    let overlay = BreakOverlayCoordinator(controller: controller, appearance: appearance)
    self.overlay = overlay
    controller.attach(overlayWindow: overlay)
    controller.pill = PreBreakPill(controller: controller, appearance: appearance)
    controller.toast = WellnessToast(appearance: appearance)
    let mic = MicrophoneSignalProvider()
    let camera = CameraSignalProvider()
    mic.onChange = { [weak controller] in controller?.refreshDetectorSignals() }
    camera.onChange = { [weak controller] in controller?.refreshDetectorSignals() }
    mic.start()
    camera.start()
    controller.microphoneSignals = mic
    controller.cameraSignals = camera
    poller.fullscreenGate = { [weak controller] in
      guard let controller else { return false }
      let state = controller.snapshot.state
      return state.phase == .headsUp || state.phase == .breaking
        || state.nextDue.timeIntervalSince(controller.clock.now()) <= 120
    }
    controller.onTick = { [weak self] in
      self?.refreshTrayState()
    }

    syncHotKeys()

    if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
      updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    #if DEBUG
      if let port = DataLocations.resolveDebugPort() {
        do {
          let server = try DebugServer(controller: controller, port: port)
          self.debugServer = server
          server.start()
          NSLog("GazeKeeper debug server active on 127.0.0.1:\(port)")
        } catch {
          NSLog("GazeKeeper debug server failed to start on port \(port): \(error)")
        }
      }
    #endif

    refreshTrayState()
  }

  func applicationWillTerminate(_ notification: Notification) {
    controller?.applicationWillTerminate()
  }

  func requestBreakNow() {
    controller?.triggerBreakNow()
  }

  func syncHotKeys() {
    guard let controller else { return }
    let sync = { [weak self] (bindings: ShortcutBindings) in
      HotKeyCenter.shared.sync(bindings: bindings) { action in
        self?.performShortcut(action)
      }
    }
    sync(controller.currentSettings.shortcuts)
    controller.onShortcutBindingsChanged = sync
  }

  private func performShortcut(_ action: ShortcutAction) {
    guard let controller else { return }
    switch action {
    case .startBreak:
      controller.triggerBreakNow()
    case .togglePause:
      controller.setPaused(byUser: !controller.snapshot.state.pausedByUser)
    case .snoozeBreak:
      controller.postpone(seconds: 300)
    }
  }

  func openSettingsWindow() {
    guard let controller, let appearance else { return }
    if let url = NSApp.windows.first(where: { $0.identifier?.rawValue == "gk-settings" }) {
      url.makeKeyAndOrderFront(nil)
      return
    }
    let window = SettingsSceneFactory.makeWindow(
      controller: controller, appearance: appearance)
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  func openWelcomeWindow() {
    let windowID = NSUserInterfaceItemIdentifier("gk-welcome")
    if let existing = NSApp.windows.first(where: { $0.identifier == windowID }) {
      existing.makeKeyAndOrderFront(nil)
      return
    }
    guard let appearance, let controller else { return }
    let window = WelcomeSceneFactory.makeWindow(controller: controller, appearance: appearance)
    window.center()
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  func openDashboardWindow() {
    guard let controller, let appearance else { return }
    if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "gk-dashboard" }) {
      existing.makeKeyAndOrderFront(nil)
      return
    }
    let window = DashboardSceneFactory.makeWindow(
      controller: controller, appearance: appearance)
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  func checkForUpdates() {
    updaterController?.checkForUpdates(nil)
  }

  func togglePause() {
    guard let controller else { return }
    controller.setPaused(byUser: !controller.snapshot.state.pausedByUser)
  }

  func activateForMenuReveal() {
    NSApp.activate(ignoringOtherApps: true)
    refreshTrayState()
  }

  private func refreshTrayState() {
    guard let controller else { return }
    trayMenuState = controller.trayMenuState
  }

}

struct SettingsSceneFactory {
  @MainActor
  static func makeWindow(controller: AppStateController, appearance: AppearanceModel) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = "Settings"
    window.identifier = NSUserInterfaceItemIdentifier("gk-settings")
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView:
        SettingsWindowView(controller: controller)
        .frame(minWidth: 720, minHeight: 560)
        .background(Tokens.Color.windowBackground)
        .environment(appearance)
    )
    return window
  }
}

struct DashboardSceneFactory {
  @MainActor
  static func makeWindow(controller: AppStateController, appearance: AppearanceModel) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = "Dashboard"
    window.identifier = NSUserInterfaceItemIdentifier("gk-dashboard")
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView:
        DashboardWindowView(controller: controller)
        .frame(minWidth: 480, minHeight: 560)
        .background(Tokens.Color.windowBackground)
        .environment(appearance)
    )
    return window
  }
}

struct WelcomeSceneFactory {
  @MainActor
  static func makeWindow(
    controller: AppStateController, appearance: AppearanceModel
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
      styleMask: [.titled, .fullSizeContentView, .closable],
      backing: .buffered, defer: false)
    window.title = "Welcome to GazeKeeper"
    window.identifier = NSUserInterfaceItemIdentifier("gk-welcome")
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: OnboardingRootView(controller: controller)
        .environment(appearance))
    return window
  }
}

extension View {
  /// Injects the appearance environment object only once boot has built it —
  /// the MenuBarExtra scene renders before `applicationDidFinishLaunching`
  /// finishes wiring the delegate.
  @MainActor
  func optionalEnvironmentObject(_ appearance: AppearanceModel?) -> some View {
    Group {
      if let appearance {
        self.environment(appearance)
      } else {
        self
      }
    }
  }
}
