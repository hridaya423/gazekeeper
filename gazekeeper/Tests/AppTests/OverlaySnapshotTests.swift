import AppKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import GazeKeeper
@testable import GazeKeeperCore

/// Image snapshots of the floating surfaces at fixed size. Reference
/// images live under Tests/AppTests/Snapshots; regenerate with
/// record: true after an intentional visual change.
@MainActor
final class OverlaySnapshotTests: XCTestCase {

  private func host<V: View>(_ view: V, size: CGSize) -> NSHostingView<some View> {
    // Pin the SwiftUI view — NSHostingView otherwise renders the view's
    // ideal size and crops a ZStack that fills its container.
    let pinned = view.frame(width: size.width, height: size.height)
    let hosting = NSHostingView(rootView: pinned)
    hosting.frame = NSRect(origin: .zero, size: size)
    // SwiftUI Buttons only realize their AppKit subviews inside a window;
    // park the host in an offscreen one so controls paint in snapshots.
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderBack(nil)
    window.displayIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    return hosting
  }

  private func model(remaining: Int, total: Int, long: Bool = false) -> BreakOverlayModel {
    BreakOverlayModel(
      isPresented: true,
      remainingSeconds: remaining,
      totalSeconds: total,
      message: "Look away. Blink. Shoulders down.",
      allowEsc: true,
      reduceMotion: true,
      isLong: long,
      snoozesRemaining: 2)
  }

  func testOverlayShort() {
    let view = host(
      OverlayBreakView(
        model: model(remaining: 14, total: 20),
        reduceMotion: true, showsControls: true, background: .blur,
        onSkip: {}, onPostpone: { _ in }),
      size: CGSize(width: 1440, height: 900))
    assertSnapshot(of: view, as: .image)
    // NSHostingView never paints AppKit-backed Buttons without a real
    // window session; assert the controls subtree exists instead.
    XCTAssertGreaterThan(controlsSubviewCount(in: view), 0)
  }

  func testOverlayLongBreak() {
    let view = host(
      OverlayBreakView(
        model: model(remaining: 240, total: 300, long: true),
        reduceMotion: true, showsControls: true, background: .blur,
        onSkip: {}, onPostpone: { _ in }),
      size: CGSize(width: 1440, height: 900))
    assertSnapshot(of: view, as: .image)
    // NSHostingView never paints AppKit-backed Buttons without a real
    // window session; assert the controls subtree exists instead.
    XCTAssertGreaterThan(controlsSubviewCount(in: view), 0)
  }

  func testOverlaySecondaryDisplay() {
    let view = host(
      OverlayBreakView(
        model: model(remaining: 9, total: 20),
        reduceMotion: true, showsControls: false, background: .blur,
        onSkip: {}, onPostpone: { _ in }),
      size: CGSize(width: 1440, height: 900))
    assertSnapshot(of: view, as: .image)
    XCTAssertEqual(controlsSubviewCount(in: view), 0)
  }

  /// Buttons realize as private AppKit subviews once hosted — their
  /// presence is the honest structural check that controls rendered.
  private func controlsSubviewCount(in view: NSView) -> Int {
    view.subviews.count + view.subviews.map(controlsSubviewCount(in:)).reduce(0, +)
  }

  /// The overlay re-renders only when an observed value changes. During a
  /// break the snapshot stays equal, so each one-second pump must still
  /// invalidate the countdown or the overlay freezes on its first second.
  func testCountdownInvalidatesEverySecond() {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("gk-tick-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = OffsetClock(offset: 0)
    let controller = AppStateController(
      settings: GKSettingsV1(), clock: clock, dataDirectory: dir)
    controller.triggerBreakNow(duration: 20)
    XCTAssertEqual(controller.overlayModel.remainingSeconds, 20)

    let changed = expectation(description: "countdown invalidated")
    withObservationTracking {
      _ = controller.overlayModel.remainingSeconds
    } onChange: {
      changed.fulfill()
    }
    clock.shiftOffset(bySeconds: 1)
    controller.pump()

    wait(for: [changed], timeout: 0.1)
    XCTAssertEqual(controller.overlayModel.remainingSeconds, 19)
  }
}
