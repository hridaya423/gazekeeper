import AppKit
import GazeKeeperCore
import SwiftUI

/// Blink and posture reminders as transient on-screen toasts: a
/// click-through panel at the bottom-center of the active display,
/// visible for four seconds then gone. Toasts don't steal focus,
/// can't be missed in a notification summary, and never stack —
/// simultaneous kinds queue and drain one at a time.
@MainActor
final class WellnessToast {

  private static let visibleSeconds: TimeInterval = 4
  private static let fadeInSeconds: TimeInterval = 0.2
  private static let fadeOutSeconds: TimeInterval = 0.3

  private var panel: NSPanel?
  private var hosting: NSHostingView<ToastView>?
  private let model = ToastModel()
  private var queue: [WellnessNudge] = []
  private var dismissTask: Task<Void, Never>?
  private let appearance: AppearanceModel

  init(appearance: AppearanceModel) {
    self.appearance = appearance
  }

  func show(_ nudge: WellnessNudge) {
    queue.append(nudge)
    if panel == nil { presentNext() }
  }

  private func presentNext() {
    guard let nudge = queue.first else {
      tearDown()
      return
    }
    model.nudge = nudge
    if panel == nil {
      let panel = NSPanel(
        contentRect: NSRect(origin: .zero, size: NSSize(width: 340, height: 64)),
        styleMask: [.nonactivatingPanel, .borderless],
        backing: .buffered,
        defer: false)
      panel.level = .floating
      panel.isFloatingPanel = true
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.ignoresMouseEvents = true
      panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
      let hosting = NSHostingView(
        rootView: ToastView(model: model, appearance: appearance))
      panel.contentView = hosting
      self.panel = panel
      self.hosting = hosting
    }
    guard let panel, let hosting else { return }
    hosting.layoutSubtreeIfNeeded()
    panel.setContentSize(hosting.fittingSize)
    if let screen = NSScreen.main ?? NSScreen.screens.first {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(
        NSPoint(
          x: frame.midX - panel.frame.width / 2,
          y: frame.minY + 140))
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    let reduceMotion = appearance.reduceMotion
    if reduceMotion {
      panel.alphaValue = 1
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Self.fadeInSeconds
        panel.animator().alphaValue = 1
      }
    }
    dismissTask?.cancel()
    dismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.visibleSeconds))
      guard !Task.isCancelled else { return }
      self?.dismissCurrent()
    }
  }

  private func dismissCurrent() {
    guard let panel else { return }
    if appearance.reduceMotion {
      finishDismissal()
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeOutSeconds
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      Task { @MainActor in self?.finishDismissal() }
    }
  }

  private func finishDismissal() {
    if !queue.isEmpty { queue.removeFirst() }
    if queue.isEmpty {
      tearDown()
    } else {
      presentNext()
    }
  }

  private func tearDown() {
    dismissTask?.cancel()
    dismissTask = nil
    panel?.orderOut(nil)
    panel = nil
    hosting = nil
    model.nudge = nil
  }
}

/// The mutable payload a toast panel renders — swapped per nudge without
/// rebuilding the panel.
@MainActor
@Observable
final class ToastModel {
  var nudge: WellnessNudge?
}

struct ToastView: View {
  let model: ToastModel
  let appearance: AppearanceModel

  var body: some View {
    if let nudge = model.nudge {
      HStack(spacing: 10) {
        Image(systemName: iconName(nudge.kind))
          .font(Tokens.Icon.toast)
          .foregroundStyle(appearance.accent)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(nudge.title)
            .font(Tokens.Typography.headline)
            .foregroundStyle(Tokens.Color.text)
          Text(nudge.body)
            .font(Tokens.Typography.callout)
            .foregroundStyle(Tokens.Color.textSecondary)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.regularMaterial)
          .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
      )
      .fixedSize()
      .accessibilityElement(children: .combine)
    }
  }

  private func iconName(_ kind: WellnessNudgeKind) -> String {
    switch kind {
    case .blink: return "eye"
    case .posture: return "figure.stand"
    case .digest: return "chart.bar.doc.horizontal"
    }
  }
}
