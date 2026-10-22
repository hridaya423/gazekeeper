import AppIntents
import Foundation

/// Every intent is a thin shell over the live controller — Shortcuts
/// drives the same engine the menu does, and failures surface as intent
/// errors rather than silent no-ops.
enum IntentFailure: LocalizedError {
  case appNotRunning
  case breaksPaused

  var errorDescription: String? {
    switch self {
    case .appNotRunning:
      return "GazeKeeper isn't running."
    case .breaksPaused:
      return "Breaks are paused — resume them first."
    }
  }
}

@MainActor
private func requireController() throws -> AppStateController {
  guard let controller = AppDelegate.shared?.controller else {
    throw IntentFailure.appNotRunning
  }
  return controller
}

struct StartBreakIntent: AppIntent {
  static var title: LocalizedStringResource { "Start a break" }
  static var description: IntentDescription {
    IntentDescription("Starts a GazeKeeper break right now.")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let controller = try requireController()
    guard !controller.snapshot.state.isPaused() else {
      throw IntentFailure.breaksPaused
    }
    controller.triggerBreakNow()
    return .result()
  }
}

struct PauseBreaksIntent: AppIntent {
  static var title: LocalizedStringResource { "Pause breaks" }
  static var description: IntentDescription {
    IntentDescription(
      "Pauses breaks — for a number of minutes, or until resumed when left empty.")
  }

  @Parameter(
    title: "Minutes",
    description: "How long to pause. Empty pauses until you resume.")
  var minutes: Int?

  @MainActor
  func perform() async throws -> some IntentResult {
    let controller = try requireController()
    if let minutes {
      controller.pauseFor(minutes: max(1, minutes))
    } else {
      controller.setPaused(byUser: true)
    }
    return .result()
  }
}

struct ResumeBreaksIntent: AppIntent {
  static var title: LocalizedStringResource { "Resume breaks" }
  static var description: IntentDescription {
    IntentDescription(
      "Lifts a manual pause. A Focus-driven pause lifts with the Focus.")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    try requireController().setPaused(byUser: false)
    return .result()
  }
}

struct SnoozeBreakIntent: AppIntent {
  static var title: LocalizedStringResource { "Snooze the next break" }
  static var description: IntentDescription {
    IntentDescription("Pushes the next break out five minutes.")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    try requireController().postpone(seconds: 300)
    return .result()
  }
}

struct NextBreakIntent: AppIntent {
  static var title: LocalizedStringResource { "Time to next break" }
  static var description: IntentDescription {
    IntentDescription("How long until the next break is due.")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let controller = try requireController()
    let seconds = Int(
      controller.snapshot.state.effectiveRemaining(from: controller.clock.now()))
    if controller.snapshot.state.isPaused() {
      return .result(dialog: "Breaks are paused.")
    }
    let minutes = max(1, Int((Double(seconds) / 60).rounded()))
    return .result(dialog: "Next break in \(minutes) minute\(minutes == 1 ? "" : "s").")
  }
}

struct TodayStatsIntent: AppIntent {
  static var title: LocalizedStringResource { "Today's stats" }
  static var description: IntentDescription {
    IntentDescription("Breaks taken, skipped, and today's screen score.")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let controller = try requireController()
    let score = controller.todayScore
    return .result(
      dialog:
        "Today: \(score.breaksTaken) taken, \(score.breaksSkipped) skipped, \(score.breaksWorked) worked through — score \(score.total) of 100."
    )
  }
}

/// Focus filter: pause breaks while the Focus is on. The system runs
/// `perform` with the configured parameter on activation and with the
/// default (`false`) on deactivation — so the flag drives both edges of
/// `pausedByFocus`, which stays independent of a manual pause.
struct PauseInFocusIntent: SetFocusFilterIntent {
  static var title: LocalizedStringResource { "Pause breaks in this Focus" }
  static var description: IntentDescription {
    IntentDescription("GazeKeeper holds breaks while this Focus is on.")
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "Pause breaks",
      subtitle: pauseBreaks ? "On while focused" : "Off")
  }

  @Parameter(title: "Pause breaks", default: true)
  var pauseBreaks: Bool

  func perform() async throws -> some IntentResult {
    await MainActor.run {
      AppDelegate.shared?.controller?.setPaused(byFocus: pauseBreaks)
    }
    return .result()
  }
}

/// Surfaces the actions in Shortcuts without any user setup.
struct GazeKeeperShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartBreakIntent(),
      phrases: ["Start a break in \(.applicationName)"],
      shortTitle: "Start a break",
      systemImageName: "eye")
    AppShortcut(
      intent: NextBreakIntent(),
      phrases: ["When is my next break in \(.applicationName)"],
      shortTitle: "Next break",
      systemImageName: "clock")
    AppShortcut(
      intent: TodayStatsIntent(),
      phrases: ["How are my breaks in \(.applicationName)"],
      shortTitle: "Today's stats",
      systemImageName: "chart.bar")
  }
}
