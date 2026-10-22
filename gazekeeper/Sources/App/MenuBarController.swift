import AppKit
import GazeKeeperCore
import SwiftUI

/// The menu-bar popover. One status card plus native-style action rows —
/// this is the surface users see dozens of times a day, so it reads like
/// a system menu, not a mini app window.
struct MenuBarController: View {
  @Environment(AppDelegate.self) private var appDelegate: AppDelegate
  @Environment(AppearanceModel.self) private var appearance: AppearanceModel

  var body: some View {
    let trayState = appDelegate.trayMenuState
    return VStack(alignment: .leading, spacing: 0) {
      CountdownHeader()
        .padding(.bottom, 8)

      if let reason = pauseExplanation {
        Text(reason)
          .font(Tokens.Typography.caption)
          .foregroundStyle(Tokens.Color.textSecondary)
          .padding(.horizontal, 10)
          .padding(.bottom, 8)
      }

      VStack(alignment: .leading, spacing: 2) {
        PopoverRow(title: "Start Break Now", glyph: "play.circle", hint: "⌘⌥B") {
          appDelegate.requestBreakNow()
        }
        .keyboardShortcut("b", modifiers: [.command, .option])
        .disabled(!trayState.canStartBreakNow)

        ChoiceRow(
          title: "Snooze", glyph: "moon.zzz",
          choices: [("5m", 300), ("10m", 600), ("15m", 900)]
        ) { appDelegate.controller?.postpone(seconds: $0) }
        .disabled(!trayState.canSnooze)
        .help(
          trayState.snoozesRemaining == 1
            ? "1 snooze left" : "\(trayState.snoozesRemaining) snoozes left")

        if trayState.pausedByUser {
          PopoverRow(title: "Resume Scheduling", glyph: "playpause") {
            appDelegate.togglePause()
          }
        } else {
          ChoiceRow(
            title: "Pause", glyph: "pause.circle",
            choices: [("30m", 30), ("1h", 60), ("Today", -1), ("∞", 0)]
          ) { minutes in
            switch minutes {
            case -1: appDelegate.controller?.pauseUntilTomorrow()
            case 0: appDelegate.togglePause()
            default: appDelegate.controller?.pauseFor(minutes: Int(minutes))
            }
          }
        }

        PopoverRow(title: "Skip Next Break", glyph: "forward.end") {
          appDelegate.controller?.skipNextBreak()
        }
        .disabled(!trayState.canSkipNextBreak)
        .accessibilityHint("Cancels the upcoming break and starts the timer over")
      }

      PopoverSeparator()

      VStack(alignment: .leading, spacing: 2) {
        PopoverRow(title: "Settings", glyph: "gearshape") {
          appDelegate.openSettingsWindow()
        }
        PopoverRow(title: "Dashboard", glyph: "chart.xyaxis.line") {
          appDelegate.openDashboardWindow()
        }
        PopoverRow(title: "Show Welcome", glyph: "sparkles") {
          appDelegate.openWelcomeWindow()
        }
        PopoverRow(title: "Check for Updates", glyph: "arrow.triangle.2.circlepath") {
          appDelegate.checkForUpdates()
        }
      }

      PopoverSeparator()

      VStack(alignment: .leading, spacing: 2) {
        PopoverRow(title: "Quit GazeKeeper", glyph: "power") {
          appDelegate.controller?.quitAfterFlush() ?? NSApp.terminate(nil)
        }
      }
    }
    .padding(8)
    .frame(width: 264)
    .gkAccent(from: appDelegate.controller?.currentSettings ?? GKSettingsV1())
  }

  private var pauseExplanation: String? {
    guard let controller = appDelegate.controller else { return nil }
    if let reason = appDelegate.trayMenuState.detectorPauseReason,
      controller.snapshot.state.pausedByDetector
    {
      return "Scheduling is paused — \(reason.lowercased())."
    }
    if trayPaused && controller.snapshot.state.pausedByDetector == false {
      return "Scheduling is paused."
    }
    return nil
  }

  private var trayPaused: Bool {
    appDelegate.trayMenuState.pausedByUser
  }
}

/// A row that behaves like an NSMenuItem: hover fill, leading glyph,
/// optional trailing hint.
private struct PopoverRowLabel: View {
  let title: String
  let glyph: String
  var hint: String? = nil
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: glyph)
        .font(Tokens.Icon.row)
        .foregroundStyle(Tokens.Color.textSecondary)
        .frame(width: 16)
      Text(title)
        .font(Tokens.Typography.body)
        .foregroundStyle(Tokens.Color.text)
      Spacer(minLength: 8)
      if let hint {
        Text(hint)
          .font(Tokens.Typography.caption)
          .foregroundStyle(Tokens.Color.textSecondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(hovering ? Tokens.Color.rowHover : .clear)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
  }
}

private struct PopoverRow: View {
  let title: String
  let glyph: String
  var hint: String? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      PopoverRowLabel(title: title, glyph: glyph, hint: hint)
    }
    .buttonStyle(PopoverRowStyle())
  }
}

/// A row whose options sit inline as small chips: one click instead of a
/// submenu, and every option visible at a glance.
private struct ChoiceRow: View {
  @Environment(\.isEnabled) private var isEnabled: Bool
  let title: String
  let glyph: String
  let choices: [(label: String, value: Double)]
  let action: (Double) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: glyph)
        .font(Tokens.Icon.row)
        .foregroundStyle(Tokens.Color.textSecondary)
        .frame(width: 16)
      Text(title)
        .font(Tokens.Typography.body)
        .foregroundStyle(Tokens.Color.text)
      Spacer(minLength: 8)
      HStack(spacing: 2) {
        ForEach(choices, id: \.label) { choice in
          Button(choice.label) { action(choice.value) }
            .buttonStyle(ChipStyle())
        }
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 4)
    .padding(.vertical, 2)
    .opacity(isEnabled ? 1 : 0.45)
  }
}

private struct ChipStyle: ButtonStyle {
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Tokens.Typography.caption.weight(.medium))
      .foregroundStyle(hovering ? Tokens.Color.text : Tokens.Color.textSecondary)
      .padding(.horizontal, 7)
      .frame(minHeight: 22)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(hovering || configuration.isPressed ? Tokens.Color.rowHover : .clear)
      )
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}

private struct PopoverRowStyle: ButtonStyle {

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

private struct PopoverSeparator: View {
  var body: some View {
    Tokens.Color.hairline
      .frame(height: 1)
      .padding(.horizontal, 6)
      .padding(.vertical, 6)
  }
}

/// The one thing people open the menu for: how long until the next break.
/// Chart-type countdown, a bar that empties toward the break, and today's
/// tally underneath so the habit is visible without opening the dashboard.
private struct CountdownHeader: View {
  @Environment(AppDelegate.self) private var appDelegate: AppDelegate
  @Environment(AppearanceModel.self) private var appearance: AppearanceModel
  @Environment(\.gkAccent) private var accent: Color

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text(statusLabel)
            .font(Tokens.Typography.keyCap)
            .kerning(0.6)
            .foregroundStyle(Tokens.Color.textSecondary)
          Spacer()
          Text(clockText(context.date))
            .font(Tokens.Typography.chart(30))
            .monospacedDigit()
            .foregroundStyle(Tokens.Color.text)
            .contentTransition(appearance.reduceMotion ? .identity : .numericText(countsDown: true))
            .animation(
              appearance.reduceMotion ? nil : Tokens.Motion.ui, value: clockText(context.date))
        }

        GeometryReader { proxy in
          Capsule().fill(Tokens.Color.separator)
            .overlay(alignment: .leading) {
              Capsule().fill(accent)
                .frame(width: proxy.size.width * fraction(context.date))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)

        if let tally {
          Text(tally)
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Color.textSecondary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)
      .padding(.bottom, 12)
      .background(
        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
          .fill(Tokens.Color.card)
      )
    }
  }

  private var statusLabel: String {
    guard let controller = appDelegate.controller else { return "NEXT BREAK" }
    if appDelegate.trayMenuState.pausedByUser || controller.snapshot.state.pausedByDetector {
      return "PAUSED"
    }
    switch controller.snapshot.state.phase {
    case .breaking: return "ON A BREAK"
    case .headsUp: return "BREAK STARTING"
    case .cooldown, .idle: return "NEXT BREAK"
    }
  }

  private var tally: String? {
    guard let score = appDelegate.controller?.todayScore else { return nil }
    return
      "Today  \(score.breaksTaken) taken · \(score.breaksPostponed) snoozed · \(score.breaksSkipped) skipped"
  }

  private func fraction(_ date: Date) -> Double {
    guard let controller = appDelegate.controller,
      controller.snapshot.state.phase != .breaking
    else { return 0 }
    let interval = Double(controller.currentSettings.intervalMinutes * 60)
    guard interval > 0 else { return 0 }
    return min(1, max(0, controller.snapshot.state.effectiveRemaining(from: date) / interval))
  }

  private func clockText(_ date: Date) -> String {
    guard let controller = appDelegate.controller else { return "--:--" }
    if controller.snapshot.state.phase == .breaking, !controller.snapshot.state.isPaused() {
      return AppStateController.format(controller.breakRemainingRounded)
    }
    let remaining = Int(max(0, ceil(controller.snapshot.state.effectiveRemaining(from: date))))
    return AppStateController.format(remaining)
  }
}
