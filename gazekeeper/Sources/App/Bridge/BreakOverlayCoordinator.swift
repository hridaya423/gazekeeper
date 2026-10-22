import AppKit
import GazeKeeperCore
import SwiftUI

@MainActor
final class BreakOverlayCoordinator {

  private struct ScreenPanel {
    let panel: NSPanel
    let isPrimary: Bool
  }

  private var panels: [ScreenPanel] = []
  private let escMonitorBox = EscMonitorBox()
  private var screenParamsObserver: NSObjectProtocol?
  private weak var controller: AppStateController?
  private let appearance: AppearanceModel
  private var visible = false

  init(controller: AppStateController, appearance: AppearanceModel) {
    self.controller = controller
    self.appearance = appearance
    rebuildPanels()
    screenParamsObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.screensDidChange() }
    }
  }

  var isVisible: Bool {
    panels.contains { $0.panel.isVisible }
  }

  var frame: NSRect {
    panels.first?.panel.frame ?? .zero
  }

  /// One panel per screen, rebuilt whenever the display set changes. The
  /// first NSScreen (the menu-bar display) gets the controls; every other
  /// panel shows the same countdown and message without them.
  private func rebuildPanels() {
    let old = panels
    panels = NSScreen.screens.enumerated().map { index, screen in
      let panel = KeyableOverlayPanel(
        contentRect: screen.frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false)
      panel.level = .screenSaver
      panel.isOpaque = true
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.ignoresMouseEvents = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.alphaValue = 0
      let hosting = NSHostingView(
        rootView: OverlayRootView(
          controller: controller!, appearance: appearance,
          showsControls: index == 0))
      hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
      hosting.autoresizingMask = [.width, .height]
      panel.contentView = hosting
      return ScreenPanel(panel: panel, isPrimary: index == 0)
    }
    for entry in old { entry.panel.orderOut(nil) }
    if visible {
      for entry in panels {
        entry.panel.alphaValue = 1
        entry.panel.orderFrontRegardless()
      }
      panels.first?.panel.makeKey()
      installEscMonitorIfNeeded()
    }
  }

  private func screensDidChange() {
    rebuildPanels()
  }

  func setVisible(_ visible: Bool) {
    guard visible != self.visible else { return }
    self.visible = visible
    let reduceMotion = controller?.reduceMotionEffective ?? true
    if visible {
      for entry in panels {
        entry.panel.alphaValue = 0
        entry.panel.orderFrontRegardless()
      }
      panels.first?.panel.makeKey()
      installEscMonitorIfNeeded()
      if reduceMotion {
        for entry in panels { entry.panel.alphaValue = 1 }
      } else {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.45
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          for entry in panels { entry.panel.animator().alphaValue = 1 }
        }
      }
    } else {
      removeEscMonitor()
      if reduceMotion {
        for entry in panels { entry.panel.orderOut(nil) }
      } else {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.3
          context.timingFunction = CAMediaTimingFunction(name: .easeIn)
          for entry in panels { entry.panel.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
          Task { @MainActor in
            guard let self else { return }
            for entry in self.panels { entry.panel.orderOut(nil) }
          }
        }
      }
    }
  }

  private func installEscMonitorIfNeeded() {
    guard escMonitorBox.monitor == nil else { return }
    escMonitorBox.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self else { return event }
      let keyCode = event.keyCode
      let modifiers = event.modifierFlags
      let consumed = MainActor.assumeIsolated {
        self.handleKeyDown(keyCode: keyCode, modifierFlags: modifiers)
      }
      return consumed ? nil : event
    }
  }

  private func removeEscMonitor() {
    if let monitor = escMonitorBox.monitor {
      NSEvent.removeMonitor(monitor)
      escMonitorBox.monitor = nil
    }
  }

  private func handleKeyDown(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
    guard keyCode == 53, modifierFlags.subtracting(.function).isEmpty else { return false }
    guard isVisible, let controller else { return false }
    guard controller.overlayModel.allowEsc else { return true }
    // Esc follows Skip's rule: active only once the break has properly
    // started — a reflexive Esc at the first frame can't nuke it.
    guard controller.overlayModel.skipRevealed else { return true }
    controller.skipBreak(reason: "esc")
    return true
  }
}

private final class KeyableOverlayPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

private final class EscMonitorBox: @unchecked Sendable {
  var monitor: Any?
}

struct OverlayRootView: View {
  let controller: AppStateController
  let appearance: AppearanceModel
  let showsControls: Bool

  var body: some View {
    if controller.snapshot.state.phase == .breaking {
      OverlayBreakView(
        model: controller.overlayModel,
        reduceMotion: controller.reduceMotionEffective,
        showsControls: showsControls,
        background: controller.overlayBackgroundResolved,
        onSkip: { controller.skipBreak() },
        onPostpone: { seconds in controller.postpone(seconds: seconds) }
      )
      .transition(.opacity)
      .gkAccent(from: controller.currentSettings)
    } else {
      Color.clear
    }
  }
}

/// What fills the screen behind the overlay content, resolved from
/// settings. `.image` carries a decoded NSImage — loading is the
/// controller's cache, not the view's job.
enum OverlayBackdrop: Equatable {
  case blur
  case solid
  case image(NSImage)

  static func == (lhs: OverlayBackdrop, rhs: OverlayBackdrop) -> Bool {
    switch (lhs, rhs) {
    case (.blur, .blur), (.solid, .solid): return true
    case (.image(let a), .image(let b)): return a === b
    default: return false
    }
  }
}

struct OverlayBreakView: View {
  @Environment(\.gkAccent) private var accent: Color

  let model: BreakOverlayModel
  let reduceMotion: Bool
  let showsControls: Bool
  let background: OverlayBackdrop
  let onSkip: () -> Void
  let onPostpone: (TimeInterval) -> Void

  var body: some View {
    GeometryReader { geometry in
      let ring = min(360, geometry.size.height * 0.4)
      ZStack {
        backdrop
        // Darker toward the edges: less light in the periphery while the
        // eyes are meant to be elsewhere.
        RadialGradient(
          colors: [.clear, Color.black.opacity(0.4)], center: .center,
          startRadius: geometry.size.height * 0.2, endRadius: geometry.size.width * 0.75)

        VStack(spacing: 0) {
          HStack {
            Text(model.isLong ? "LONG BREAK" : "EYE BREAK")
            Spacer()
            if let left = model.snoozesRemaining {
              Text(left == 1 ? "1 SNOOZE LEFT" : "\(left) SNOOZES LEFT")
            }
          }
          .font(Tokens.Typography.keyCap)
          .kerning(1)
          .foregroundStyle(Tokens.Color.onScrimSecondary)

          Spacer()

          ZStack {
            BreakDial(
              remaining: model.remainingSeconds, total: model.totalSeconds,
              animated: !reduceMotion
            )
            .frame(width: ring, height: ring)
            VStack(spacing: ring * 0.04) {
              Text(clockText)
                .font(Tokens.Typography.chart(ring * (model.remainingSeconds >= 100 ? 0.24 : 0.36)))
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.onScrim)
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                .animation(reduceMotion ? nil : Tokens.Motion.ui, value: model.remainingSeconds)
              Text(model.remainingSeconds >= 100 ? "MINUTES" : "SECONDS")
                .font(Tokens.Typography.keyCap)
                .kerning(1.5)
                .foregroundStyle(Tokens.Color.onScrimSecondary)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Break time remaining")
          .accessibilityValue("\(model.remainingSeconds) seconds")
          .padding(.bottom, 40)

          Text(model.message)
            .font(Tokens.Typography.overlayMessage)
            .foregroundStyle(Tokens.Color.onScrim)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 640)

          Spacer()

          if showsControls {
            HStack(spacing: 12) {
              Button("Snooze 5 min") { onPostpone(300) }
                .buttonStyle(OverlayChipStyle(filled: true, reduceMotion: reduceMotion))
                .disabled(model.snoozesRemaining == 0)
              if model.skipRevealed {
                Button(action: onSkip) {
                  HStack(spacing: 8) {
                    Text("Skip")
                    if model.allowEsc {
                      Text("esc").font(Tokens.Typography.keyCap)
                        .foregroundStyle(Tokens.Color.onScrimSecondary.opacity(0.7))
                    }
                  }
                }
                .buttonStyle(OverlayChipStyle(filled: false, reduceMotion: reduceMotion))
                .transition(.opacity)
              }
            }
            .frame(height: 44)
          }
        }
        .padding(56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .animation(reduceMotion ? nil : Tokens.Motion.ui, value: model.skipRevealed)
    }
    .focusable(false)
  }

  /// The backdrop keeps content legible in all three modes — a dim layer
  /// sits over everything, blur and image just differ in what it dims.
  @ViewBuilder private var backdrop: some View {
    switch background {
    case .blur:
      Tokens.Color.scrim
      Rectangle().fill(.ultraThinMaterial)
    case .solid:
      Tokens.Color.overlaySolid
    case .image(let image):
      GeometryReader { proxy in
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipped()
      }
      // A fixed dim over any image keeps the ring and copy readable.
      Tokens.Color.scrim
      Rectangle().fill(.ultraThinMaterial.opacity(0.5))
    }
  }

  private var clockText: String {
    // Long breaks read as m:ss; sub-100-second breaks keep the raw
    // countdown the product is built around.
    if model.remainingSeconds >= 100 {
      return String(format: "%d:%02d", model.remainingSeconds / 60, model.remainingSeconds % 60)
    }
    return String(format: "%02d", model.remainingSeconds)
  }
}

/// Capsule controls on the break scrim: one filled, the rest quiet.
private struct OverlayChipStyle: ButtonStyle {
  let filled: Bool
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Tokens.Typography.controlTitle)
      .foregroundStyle(filled ? Tokens.Color.onScrim : Tokens.Color.onScrimSecondary)
      .padding(.horizontal, 18)
      .frame(minHeight: 40)
      .background(Capsule().fill(filled ? Tokens.Color.onScrimFill : .clear))
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .animation(reduceMotion ? nil : Tokens.Motion.ui, value: configuration.isPressed)
  }
}

/// An optician's dial: one tick per second of the break (a tick per
/// second up to 60, then 60 ticks), lit for the time left. Ticks go dark
/// one at a time from the end, so the dial empties clockwise to twelve.
struct BreakDial: View {
  @Environment(\.gkAccent) private var accent: Color

  let remaining: Int
  let total: Int
  let animated: Bool

  var body: some View {
    GeometryReader { geometry in
      let dimension = min(geometry.size.width, geometry.size.height)
      let count = max(1, min(60, total))
      let share = total > 0 ? Double(remaining) / Double(total) : 0
      let lit = Int((share * Double(count)).rounded(.up))
      let width = max(2, dimension * 0.012)
      let length = dimension * (count > 30 ? 0.05 : 0.075)
      ZStack {
        ForEach(0..<count, id: \.self) { index in
          Capsule()
            .fill(index < lit ? accent : Tokens.Color.onScrimFill)
            .frame(width: width, height: length)
            .offset(y: -(dimension - length) / 2)
            .rotationEffect(.degrees(Double(index) / Double(count) * 360))
        }
      }
      .frame(width: dimension, height: dimension)
      .animation(animated ? .easeOut(duration: 0.6) : nil, value: lit)
    }
    .accessibilityHidden(true)
  }
}
