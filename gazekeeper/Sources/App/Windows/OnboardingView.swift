import GazeKeeperCore
import SwiftUI
import UserNotifications

/// First run: three steps, each of which sets something real — the
/// rhythm, what holds a break, and how the app starts. The eye chart on
/// the left is the progress: each step's line comes into focus as you
/// reach it.
struct OnboardingRootView: View {
  @Environment(AppearanceModel.self) private var appearance: AppearanceModel
  let controller: AppStateController

  @State private var step = 0
  @State private var openAtLogin = true

  private let steps = ["Rhythm", "Holds", "Start"]

  var body: some View {
    HStack(spacing: 0) {
      ChartRail(steps: steps, step: step)
        .frame(width: 260)

      VStack(alignment: .leading, spacing: 0) {
        Group {
          switch step {
          case 0: RhythmStep(controller: controller)
          case 1: HoldsStep(controller: controller)
          default: StartStep(controller: controller, openAtLogin: $openAtLogin)
          }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
        .id(step)

        HStack {
          if step > 0 {
            Button("Back") { step -= 1 }
              .buttonStyle(.plain)
              .foregroundStyle(Tokens.Color.textSecondary)
          }
          Spacer()
          Button(step == steps.count - 1 ? "Start GazeKeeper" : "Continue") {
            if step == steps.count - 1 { finish() } else { step += 1 }
          }
          .buttonStyle(PrimaryCapsuleStyle(reduceMotion: appearance.reduceMotion))
          .keyboardShortcut(.defaultAction)
        }
      }
      .padding(Tokens.Spacing.xl)
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 760, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
    .background(Tokens.Color.windowBackground)
    .ignoresSafeArea()
    .tint(appearance.accent)
    .animation(appearance.reduceMotion ? nil : Tokens.Motion.gentle, value: step)
    .environment(\.gkAccent, appearance.accent)
    .environment(\.gkOnAccent, appearance.onAccent)
    .accessibilityIdentifier("gk-onboarding-root")
  }

  private func finish() {
    controller.updateSettings { $0.launchAtLogin = openAtLogin }
    appearance.completeOnboarding()
    NSApp.windows.first(where: { $0.identifier?.rawValue == "gk-welcome" })?.close()
  }
}

/// The site's eye chart, set as progress. Lines for steps not yet reached
/// sit out of focus; the current one is underlined in the accent.
private struct ChartRail: View {
  @Environment(\.gkAccent) private var accent: Color
  let steps: [String]
  let step: Int

  private static let stepLines: [(CGFloat, String)] = [(19, "20/70"), (15, "20/50"), (12, "20/30")]

  var body: some View {
    let lines: [(text: String, size: CGFloat, acuity: String)] =
      [("GAZE", 46, "20/200"), ("KEEPER", 30, "20/100")]
      + zip(steps, Self.stepLines).map { name, line in (name.uppercased(), line.0, line.1) }
    VStack(spacing: 18) {
      Spacer()
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        let stepIndex = index - 2
        let current = stepIndex == step
        let ahead = stepIndex > step
        HStack(alignment: .firstTextBaseline) {
          Text("\(index + 1)")
            .frame(width: 14, alignment: .leading)
          Spacer()
          Text(line.text)
            .font(Tokens.Typography.chart(line.size))
            .kerning(line.size * 0.12)
            .foregroundStyle(current ? accent : Tokens.Color.text)
            .blur(radius: ahead ? 2 : 0)
            .opacity(ahead ? 0.5 : 1)
          Spacer()
          Text(line.acuity)
            .frame(width: 44, alignment: .trailing)
        }
        .font(Tokens.Typography.keyCap)
        .foregroundStyle(current ? accent : Tokens.Color.textTertiary)
        .padding(.bottom, current ? 8 : 0)
        .overlay(alignment: .bottom) {
          if current {
            accent.frame(height: 1)
          }
        }
      }
      Spacer()
    }
    .padding(.horizontal, Tokens.Spacing.l)
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
    .overlay(alignment: .trailing) {
      Tokens.Color.separator.frame(width: 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Step \(step + 1) of \(steps.count): \(steps[step])")
  }
}

/// The one filled control in the window. It keeps its accent fill when the
/// window is inactive, where `.borderedProminent` would fade to grey.
private struct PrimaryCapsuleStyle: ButtonStyle {
  @Environment(\.gkAccent) private var accent: Color
  @Environment(\.gkOnAccent) private var onAccent: Color
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Tokens.Typography.controlTitle)
      .foregroundStyle(onAccent)
      .padding(.horizontal, 20)
      .frame(minHeight: 36)
      .background(Capsule().fill(accent))
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .animation(reduceMotion ? nil : Tokens.Motion.ui, value: configuration.isPressed)
  }
}

private struct StepHeader: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      Text(title)
        .font(.system(size: 26, weight: .semibold))
        .kerning(-0.4)
      Text(detail)
        .font(.system(size: 14))
        .foregroundStyle(Tokens.Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.bottom, Tokens.Spacing.l)
  }
}

private struct RhythmStep: View {
  let controller: AppStateController

  private let presets: [(minutes: Int, seconds: Int, title: String, note: String)] = [
    (
      20, 20, "Every 20 minutes, 20 seconds",
      "The 20-20-20 rule. Short and frequent."
    ),
    (30, 60, "Every 30 minutes, 1 minute", "Fewer interruptions, a little longer each."),
    (50, 300, "Every 50 minutes, 5 minutes", "Long focus blocks. Stand up when it lands."),
  ]

  var body: some View {
    let settings = controller.currentSettings
    VStack(alignment: .leading, spacing: 0) {
      StepHeader(
        title: "How often should it ask?",
        detail: "You can change both numbers in Settings at any time.")
      VStack(spacing: Tokens.Spacing.xs) {
        ForEach(presets, id: \.minutes) { preset in
          ChoiceRow(
            title: preset.title, note: preset.note,
            selected: settings.intervalMinutes == preset.minutes
              && settings.breakSeconds == preset.seconds
          ) {
            controller.updateSettings {
              $0.intervalMinutes = preset.minutes
              $0.breakSeconds = preset.seconds
            }
          }
        }
      }
    }
  }
}

private struct ChoiceRow: View {
  @Environment(\.gkAccent) private var accent: Color
  let title: String
  let note: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Tokens.Spacing.s) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(Tokens.Typography.headline)
          Text(note).font(Tokens.Typography.callout).foregroundStyle(Tokens.Color.textSecondary)
        }
        Spacer()
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 16))
          .foregroundStyle(selected ? accent : Tokens.Color.textTertiary)
      }
      .padding(.horizontal, Tokens.Spacing.m)
      .frame(minHeight: 56)
      .background(
        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
          .strokeBorder(selected ? accent : Tokens.Color.separator, lineWidth: selected ? 1.5 : 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct HoldsStep: View {
  let controller: AppStateController
  @State private var notifications: UNAuthorizationStatus = .notDetermined

  private let detectors = [
    ("camera", "Camera in use"),
    ("microphone", "Microphone in use"),
    ("screenSharing", "Screen sharing"),
    ("fullscreen", "Fullscreen apps"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      StepHeader(
        title: "When should it wait?",
        detail: "A break due during any of these is held until the moment passes.")
      VStack(alignment: .leading, spacing: 10) {
        ForEach(detectors, id: \.0) { id, label in
          Toggle(isOn: binding(id)) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .toggleStyle(.switch)
      .font(.system(size: 13))

      Divider().padding(.vertical, Tokens.Spacing.m)

      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Notifications").font(Tokens.Typography.headline)
          Text("Only used when a fullscreen app hides the heads-up.")
            .font(Tokens.Typography.callout)
            .foregroundStyle(Tokens.Color.textSecondary)
        }
        Spacer()
        switch notifications {
        case .notDetermined:
          Button("Allow") { request() }
        case .denied:
          Text("Off in System Settings").font(Tokens.Typography.callout)
            .foregroundStyle(Tokens.Color.textSecondary)
        default:
          Label("Allowed", systemImage: "checkmark")
            .font(Tokens.Typography.callout)
            .foregroundStyle(Tokens.Color.textSecondary)
        }
      }
    }
    .task {
      notifications = await UNUserNotificationCenter.current().notificationSettings()
        .authorizationStatus
    }
  }

  private func binding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { controller.currentSettings.detectors[id]?.enabled ?? true },
      set: { on in
        controller.updateSettings { $0.detectors[id, default: DetectorSettings()].enabled = on }
      })
  }

  private func request() {
    Task {
      let center = UNUserNotificationCenter.current()
      _ = try? await center.requestAuthorization(options: [.alert, .sound])
      notifications = await center.notificationSettings().authorizationStatus
    }
  }
}

private struct StartStep: View {
  let controller: AppStateController
  @Binding var openAtLogin: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      StepHeader(
        title: "That's it.",
        detail:
          "GazeKeeper lives in the menu bar. The iris empties as the next break nears; click it to snooze, pause, or see your stats."
      )
      Toggle(isOn: $openAtLogin) {
        Text("Open GazeKeeper at login").frame(maxWidth: .infinity, alignment: .leading)
      }
      .toggleStyle(.switch)
      .font(.system(size: 13))
      Divider().padding(.vertical, Tokens.Spacing.m)
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("See what a break looks like").font(Tokens.Typography.headline)
          Text("Five seconds. It counts as a real break.")
            .font(Tokens.Typography.callout)
            .foregroundStyle(Tokens.Color.textSecondary)
        }
        Spacer()
        Button("Try one") { controller.triggerBreakNow(duration: 5) }
      }
    }
  }
}
