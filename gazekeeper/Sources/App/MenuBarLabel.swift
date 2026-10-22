import AppKit
import GazeKeeperCore
import SwiftUI

/// The menu-bar mark: a depleting ring plus an optional countdown.
///
/// `MenuBarExtra` rasterizes its label into the status button, so the
/// label stays plain `Image` + `Text` — shapes or a `TimelineView` here
/// re-render the button in a tight loop. The controller's wake timer
/// re-publishes the snapshot on every minute boundary (every second in
/// the final minute when the text shows), which is the only clock.
struct MenuBarLabel: View {
  @Environment(AppDelegate.self) private var appDelegate: AppDelegate

  var body: some View {
    if let controller = appDelegate.controller {
      let state = controller.snapshot.state
      let now = controller.snapshotDate
      let remaining = Self.remaining(state, at: now)
      HStack(spacing: 4) {
        Image(
          nsImage: Self.iris(
            fraction: Self.fraction(
              state, remaining: remaining,
              interval: Double(controller.currentSettings.intervalMinutes * 60)),
            pupil: state.isPaused() ? .paused : state.phase == .breaking ? .wide : .normal))
        if controller.currentSettings.menuBarCountdown, !state.isPaused() {
          Text(Self.countdown(remaining)).monospacedDigit()
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Self.accessibilityText(state, remaining: remaining))
    } else {
      Image(nsImage: Self.iris(fraction: 0, pupil: .normal))
    }
  }

  private static func remaining(_ state: SchedulerState, at now: Date) -> TimeInterval {
    state.phase == .breaking
      ? max(0, (state.breakEndsAt ?? now).timeIntervalSince(now))
      : max(0, state.effectiveRemaining(from: now))
  }

  private static func fraction(
    _ state: SchedulerState, remaining: TimeInterval, interval: Double
  ) -> Double {
    guard state.phase != .breaking, interval > 0 else { return 0 }
    return min(1, max(0, remaining / interval))
  }

  /// "12m" until the final minute, then "0:47".
  private static func countdown(_ remaining: TimeInterval) -> String {
    remaining >= 60
      ? "\(Int(ceil(remaining / 60)))m"
      : String(format: "0:%02d", Int(remaining.rounded(.up)))
  }

  private static func accessibilityText(_ state: SchedulerState, remaining: TimeInterval) -> String
  {
    if state.isPaused() { return "GazeKeeper, breaks paused" }
    let minutes = Int(ceil(remaining / 60))
    let unit = minutes == 1 ? "minute" : "minutes"
    return state.phase == .breaking
      ? "GazeKeeper, \(minutes) \(unit) of break left"
      : "GazeKeeper, next break in \(minutes) \(unit)"
  }

  enum Pupil { case normal, wide, paused }

  /// A 16 pt template iris, the app icon at menu-bar size: a faint track,
  /// the arc of time left (it empties as the next break nears) and a pupil
  /// that widens while the break runs. Paused swaps the pupil for two bars.
  /// Template rendering lets the menu bar tint it like every system item.
  private static func iris(fraction: Double, pupil: Pupil) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
      let center = NSPoint(x: rect.midX, y: rect.midY)
      let circle = rect.insetBy(dx: 1.75, dy: 1.75)
      let track = NSBezierPath(ovalIn: circle)
      track.lineWidth = 1.5
      NSColor.black.withAlphaComponent(0.3).setStroke()
      track.stroke()
      NSColor.black.setStroke()
      NSColor.black.setFill()
      if fraction > 0 {
        let arc = NSBezierPath()
        arc.appendArc(
          withCenter: center, radius: circle.width / 2,
          startAngle: 90, endAngle: 90 - 360 * min(1, fraction), clockwise: true)
        arc.lineWidth = 1.5
        arc.lineCapStyle = .round
        arc.stroke()
      }
      switch pupil {
      case .normal, .wide:
        let r: CGFloat = pupil == .wide ? 3.6 : 2.1
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
          .fill()
      case .paused:
        for dx: CGFloat in [-1.9, 1.9] {
          NSBezierPath(
            roundedRect: NSRect(x: center.x + dx - 0.75, y: center.y - 2.5, width: 1.5, height: 5),
            xRadius: 0.75, yRadius: 0.75
          ).fill()
        }
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}
