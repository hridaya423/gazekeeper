import AppKit
import GazeKeeperCore
import SwiftUI

/// The pre-break heads-up as a real on-screen surface: a non-activating
/// floating panel pinned top-center of the active display. It replaces
/// the notification heads-up — a notification can be missed or banished
/// to a summary; the pill is where the user's eyes already are.
@MainActor
final class PreBreakPill {

  private var panel: NSPanel?
  private weak var controller: AppStateController?
  private let appearance: AppearanceModel

  init(controller: AppStateController, appearance: AppearanceModel) {
    self.controller = controller
    self.appearance = appearance
  }

  var isVisible: Bool { panel?.isVisible ?? false }

  /// Called on every state change — the single source of truth for
  /// whether the pill should be on screen. `suppressed` covers the case
  /// where a fullscreen app owns the display but the fullscreen detector
  /// is off: the heads-up then goes through a system notification
  /// instead of floating a panel over their content.
  func sync(state: SchedulerState, suppressed: Bool = false) {
    let shouldShow =
      state.phase == .headsUp && !state.isPaused() && !state.isAway && !suppressed
    if shouldShow { show() } else { hide() }
  }

  private func show() {
    guard let controller else { return }
    if panel == nil {
      let size = NSSize(width: 400, height: 56)
      let panel = NSPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.nonactivatingPanel, .borderless],
        backing: .buffered,
        defer: false)
      panel.level = .floating
      panel.isFloatingPanel = true
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.ignoresMouseEvents = false
      panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
      panel.contentView = NSHostingView(
        rootView: PillView(controller: controller, appearance: appearance))
      self.panel = panel
    }
    guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let frame = screen.visibleFrame
    let origin = NSPoint(
      x: frame.midX - panel.frame.width / 2,
      y: frame.maxY - panel.frame.height - 12)
    targetOrigin = origin
    if panel.isVisible {
      // sync() calls show() on every state change while the heads-up is
      // live — only the reveal below animates; a live pill just tracks
      // the target position.
      panel.setFrameOrigin(origin)
      panel.orderFrontRegardless()
      return
    }
    let reduceMotion = controller.reduceMotionEffective
    if !reduceMotion {
      // First reveal: drop in from just above the final resting point.
      panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 8))
    } else {
      panel.setFrameOrigin(origin)
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0.15 : 0.25
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
      if !reduceMotion {
        panel.animator().setFrameOrigin(origin)
      }
    }
  }

  private var targetOrigin = NSPoint.zero

  private func hide() {
    guard let panel else { return }
    let reduceMotion = controller?.reduceMotionEffective ?? true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0.1 : 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
      if !reduceMotion {
        panel.animator().setFrameOrigin(
          NSPoint(x: targetOrigin.x, y: targetOrigin.y + 8))
      }
    } completionHandler: {
      Task { @MainActor in panel.orderOut(nil) }
    }
    self.panel = nil
  }
}

/// "Break in 0:10 — Start now — Snooze 5m". While the typing-lull hold is
/// active the countdown reads as a promise instead: the break is waiting
/// for your hands to stop, not your attention.
struct PillView: View {
  @Environment(\.gkAccent) private var accent: Color
  let controller: AppStateController
  let appearance: AppearanceModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: 12) {
        ZStack {
          Circle().stroke(Tokens.Color.separator, lineWidth: 2)
          Circle()
            .trim(from: 0, to: fraction(at: context.date))
            .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)

        label(at: context.date)
          .font(Tokens.Typography.pillCountdown)
          .lineLimit(1)
          .fixedSize()
          .contentTransition(appearance.reduceMotion ? .identity : .numericText())

        Spacer(minLength: 8)

        Button("Start now") {
          controller.triggerBreakNow()
        }
        .buttonStyle(PillActionStyle(prominent: true))

        Button("Snooze 5m") {
          controller.postpone(seconds: 300)
        }
        .buttonStyle(PillActionStyle(prominent: false))
        .disabled(controller.trayMenuState.snoozesRemaining <= 0)
      }
      .padding(.horizontal, 16)
      .frame(width: 400, height: 56)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(.regularMaterial)
          .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
      )
    }
    .gkAccent(from: controller.currentSettings)
  }

  private func fraction(at now: Date) -> Double {
    let state = controller.snapshot.state
    let lead = Double(controller.currentSettings.headsUpSeconds)
    guard state.phase == .headsUp, lead > 0 else { return 0 }
    return min(1, max(0, state.nextDue.timeIntervalSince(now) / lead))
  }

  private func label(at now: Date) -> Text {
    let state = controller.snapshot.state
    guard state.phase == .headsUp else { return Text("") }
    let remaining = state.nextDue.timeIntervalSince(now)
    if remaining > 0 {
      let s = Int(remaining.rounded(.up))
      return Text("Break in ")
        .foregroundStyle(Tokens.Color.textSecondary)
        + Text("\(s / 60):\(String(format: "%02d", s % 60))")
        .foregroundStyle(accent)
    }
    return Text("When you pause\u{2026}")
      .foregroundStyle(Tokens.Color.text)
  }
}

private struct PillActionStyle: ButtonStyle {
  @Environment(\.gkAccent) private var accent: Color
  @Environment(\.gkOnAccent) private var onAccent: Color
  let prominent: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Tokens.Typography.chipLabel)
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(prominent ? onAccent : Tokens.Color.text.opacity(0.9))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        Capsule()
          .fill(
            prominent
              ? accent.opacity(configuration.isPressed ? 0.8 : 1)
              : Tokens.Color.rowHover.opacity(configuration.isPressed ? 1.4 : 1)))
  }
}
