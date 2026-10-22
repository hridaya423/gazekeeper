import AppKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import GazeKeeper
@testable import GazeKeeperCore

/// Composition snapshots for the remaining surfaces. Buttons still
/// don't paint without a window session — these pin layout, color,
/// and type; control presence is covered by structure assertions.
@MainActor
final class SurfaceSnapshotTests: XCTestCase {

  private var window: NSWindow?
  private var controller: AppStateController?
  private var appearance: AppearanceModel?
  private var clock: OffsetClock?
  private var directory: URL?

  private func host<V: View>(_ view: V, size: CGSize, lightMode: Bool = false) -> NSHostingView<
    some View
  > {
    // Pin locale + timezone so date/number format styles resolve
    // identically on any machine the suite runs on.
    let pinned =
      view
      .environment(\.timeZone, TimeZone(identifier: "UTC")!)
      .environment(\.locale, Locale(identifier: "en_GB"))
      .frame(width: size.width, height: size.height)
    let hosting = NSHostingView(rootView: pinned)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderBack(nil)
    if lightMode {
      hosting.appearance = NSAppearance(named: .aqua)
    }
    window.displayIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    self.window = window
    return hosting
  }

  /// A live controller on a throwaway data dir — snapshot tests exercise
  /// the real model path, not a mock.
  private func makeController() -> (AppStateController, AppearanceModel) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("gk-snap-\(UUID().uuidString)")
    directory = dir
    // Pin "now" to a fixed epoch so surfaces that render absolute
    // times (the settings status header) are deterministic. The
    // stored nextDue is an absolute Date, so later real-time drift
    // of the offset clock cannot change what renders.
    let fixedNow = Date(timeIntervalSince1970: 1_760_275_230)
    let clock = OffsetClock(offset: fixedNow.timeIntervalSinceNow)
    self.clock = clock
    let c = AppStateController(
      settings: GKSettingsV1(), clock: clock, dataDirectory: dir)
    let a = AppearanceModel(controller: c)
    controller = c
    appearance = a
    return (c, a)
  }

  func testPreBreakPill() {
    let (controller, appearance) = makeController()
    // Heads-up begins at nextDue — jump the clock past it so the
    // scheduler enters the phase the pill actually renders.
    controller.updateSettings {
      $0.intervalMinutes = 1
      $0.headsUpSeconds = 120
    }
    clock?.shiftOffset(bySeconds: 70)
    controller.pump()
    let view = host(
      PillView(controller: controller, appearance: appearance),
      size: CGSize(width: 400, height: 56))
    assertSnapshot(of: view, as: .image)
  }

  func testWellnessToast() {
    let (_, appearance) = makeController()
    let model = ToastModel()
    model.nudge = WellnessNudge(
      kind: .blink,
      body: "A few slow blinks rewet the surface of your eyes.",
      at: Date())
    let view = host(
      ToastView(model: model, appearance: appearance)
        .padding(20),
      size: CGSize(width: 380, height: 100))
    assertSnapshot(of: view, as: .image)
  }

  func testOnboardingWelcome() {
    let (controller, appearance) = makeController()
    let view = host(
      OnboardingRootView(controller: controller)
        .environment(appearance),
      size: CGSize(width: 760, height: 460))
    assertSnapshot(of: view, as: .image)
  }

  func testSettings() {
    let (controller, appearance) = makeController()
    let view = host(
      SettingsWindowView(controller: controller)
        .environment(appearance),
      size: CGSize(width: 760, height: 620))
    assertSnapshot(of: view, as: .image)
  }

  func testSettingsLight() {
    let (controller, appearance) = makeController()
    let view = host(
      SettingsWindowView(controller: controller)
        .environment(appearance),
      size: CGSize(width: 760, height: 620), lightMode: true)
    assertSnapshot(of: view, as: .image)
  }

  func testSettingsBreakScreen() {
    let (controller, appearance) = makeController()
    controller.updateSettings { $0.overlayBackground = .solid }
    let view = host(
      SettingsWindowView(controller: controller, pane: .breakScreen)
        .environment(appearance),
      size: CGSize(width: 760, height: 620))
    assertSnapshot(of: view, as: .image)
  }

  func testDashboardLight() {
    let (controller, appearance) = makeController()
    let view = host(
      DashboardWindowView(controller: controller)
        .environment(appearance),
      size: CGSize(width: 620, height: 700), lightMode: true)
    assertSnapshot(of: view, as: .image)
  }

  func testDashboard() {
    let (controller, appearance) = makeController()
    let view = host(
      DashboardWindowView(controller: controller)
        .environment(appearance),
      size: CGSize(width: 620, height: 700))
    assertSnapshot(of: view, as: .image)
  }

  /// The popover pins its degraded "no controller" state: the live
  /// countdown is wall-clock driven and would flake at second
  /// granularity. Rows, spacing, and surfaces are what this snapshot
  /// exists to protect.
  func testMenuPopover() {
    let (controller, appearance) = makeController()
    let delegate = AppDelegate(controller: controller)
    let view = host(
      MenuBarController()
        .environment(delegate)
        .environment(appearance)
        .background(Tokens.Color.windowBackground),
      size: CGSize(width: 264, height: 400))
    assertSnapshot(of: view, as: .image)
  }
}
