import AppKit
import GazeKeeperCore
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String, CaseIterable, Identifiable {
  case schedule = "Schedule"
  case smartPause = "Smart pause"
  case breakScreen = "Break screen"
  case nudges = "Nudges"
  case shortcuts = "Shortcuts"
  case general = "General"

  var id: Self { self }

  var summary: String {
    switch self {
    case .schedule: return "How often a break comes, how long it lasts, and when it may run."
    case .smartPause: return "Moments when a break waits instead of interrupting."
    case .breakScreen: return "What fills the screen while you look away."
    case .nudges: return "Small reminders between breaks to sit up and blink."
    case .shortcuts: return "Global keys that work from any app."
    case .general: return "Login, menu bar, colour and your data."
    }
  }
}

/// Settings reads like an eye chart: a rail of lines on the left, one pane
/// at a time on the right. Controls inside each pane stay native.
struct SettingsWindowView: View {
  let controller: AppStateController
  @State private var pane: SettingsPane

  init(controller: AppStateController, pane: SettingsPane = .schedule) {
    self.controller = controller
    _pane = State(initialValue: pane)
  }

  /// Re-read on every snapshot tick — registration failures land here
  /// after each settings write or app launch.
  private var failedShortcuts: Set<ShortcutAction> {
    HotKeyCenter.shared.failedActions
  }
  private static let daySymbols = ["S", "M", "T", "W", "T", "F", "S"]
  /// A denied calendar request keeps the hint visible until the next
  /// toggle; a revoked grant surfaces through `calendarAccessGranted`.
  @State private var showCalendarDenied = false

  /// Turning the feature on asks for calendar access first — the flag
  /// only lands when access is granted, so the toggle never lies.
  private var calendarAwareBinding: Binding<Bool> {
    Binding(
      get: { controller.currentSettings.calendarAware },
      set: { on in
        if on && !controller.calendarAccessGranted {
          controller.requestCalendarAccess { granted in
            if granted {
              controller.updateSettings { $0.calendarAware = true }
            } else {
              showCalendarDenied = true
            }
          }
        } else {
          showCalendarDenied = false
          controller.updateSettings { $0.calendarAware = on }
        }
      })
  }

  var body: some View {
    HStack(spacing: 0) {
      SettingsRail(selection: $pane, status: statusLine)
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          Text(pane.rawValue.uppercased())
            .font(Tokens.Typography.chart(30))
            .kerning(3)
            .foregroundStyle(Tokens.Color.text)
          Text(pane.summary)
            .font(Tokens.Typography.body)
            .foregroundStyle(Tokens.Color.textSecondary)
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.top, Tokens.Spacing.l)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)

        Form { content }
          .formStyle(.grouped)
          .scrollContentBackground(.hidden)
          .id(pane)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .background(Tokens.Color.windowBackground)
    .navigationTitle("Settings")
    .gkAccent(from: controller.currentSettings)
  }

  @ViewBuilder private var content: some View {
    switch pane {
    case .schedule: schedulePane
    case .smartPause: smartPausePane
    case .breakScreen: breakScreenPane
    case .nudges: nudgesPane
    case .shortcuts: shortcutsPane
    case .general: generalPane
    }
  }

  @ViewBuilder private var schedulePane: some View {
    Section {
      HStack(alignment: .top, spacing: 0) {
        RuleFigure(
          title: "Every", value: binding(\.intervalMinutes),
          range: GazeKeeperSettings.intervalRange, unit: "min")
        RuleFigure(
          title: "Look away for", value: binding(\.breakSeconds),
          range: GazeKeeperSettings.breakRange, unit: "sec")
      }
      .padding(.vertical, 6)
    }

    Section {
      stepperRow(
        "Snoozes per break", value: binding(\.snoozeLimit),
        range: GazeKeeperSettings.snoozeLimitRange,
        format: { $0 == 0 ? "none" : "\($0)" })
      stepperRow(
        "Long break every", value: binding(\.longBreakEvery),
        range: GazeKeeperSettings.longBreakEveryRange,
        format: { $0 == 0 ? "never" : "\($0) breaks" })
      if controller.currentSettings.longBreakEvery > 0 {
        stepperRow(
          "Long break length", value: binding(\.longBreakSeconds),
          range: GazeKeeperSettings.longBreakSecondsRange, unit: "sec")
      }
    }

    Section("Office hours") {
      Toggle("Limit to office hours", isOn: binding(\.officeHours.enabled))
        .toggleStyle(.switch)
      if controller.currentSettings.officeHours.enabled {
        timeRangeRow(
          label: "Active window",
          start: { controller.currentSettings.officeHours.startMinuteOfDay },
          setStart: { m in controller.updateSettings { $0.officeHours.startMinuteOfDay = m } },
          end: { controller.currentSettings.officeHours.endMinuteOfDay },
          setEnd: { m in controller.updateSettings { $0.officeHours.endMinuteOfDay = m } },
          a11yStart: "Office hours start", a11yEnd: "Office hours end")
        dayToggles
        Text("Windows past midnight are supported. No day selected means every day.")
          .font(Tokens.Typography.caption)
          .foregroundStyle(Tokens.Color.textSecondary)
      }
    }

    Section("Calendar") {
      Toggle("Offer breaks before meetings", isOn: calendarAwareBinding)
        .toggleStyle(.switch)
      if showCalendarDenied
        || (controller.currentSettings.calendarAware && !controller.calendarAccessGranted)
      {
        HStack(spacing: Tokens.Spacing.xs) {
          Text("Calendar access is off — nothing will be scheduled around meetings.")
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Color.textSecondary)
          Spacer()
          Button("Open Settings") {
            NSWorkspace.shared.open(
              URL(
                string:
                  "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars"
              )!)
          }
          .controlSize(.small)
        }
      }
      Text(
        "A break that would land in the last two minutes before a meeting is offered just before it starts instead."
      )
      .font(Tokens.Typography.caption)
      .foregroundStyle(Tokens.Color.textSecondary)
    }
  }

  @ViewBuilder private var smartPausePane: some View {
    Section("Hold the break while") {
      detectorToggle("The camera is in use", id: "camera")
      detectorToggle("The microphone is in use", id: "microphone")
      detectorToggle("The screen is being shared", id: "screenSharing")
      detectorToggle("An app is fullscreen", id: "fullscreen")
    }
    Section {
      stepperRow(
        "Away counts as a break after", value: binding(\.naturalBreakIdleMinutes),
        range: GazeKeeperSettings.naturalBreakIdleRange, unit: "min")
    }
    Section {
      AppRulesEditor(controller: controller)
    }
  }

  @ViewBuilder private var breakScreenPane: some View {
    Section {
      OverlayPreview(controller: controller)
        .padding(.vertical, 4)
      Picker("Background", selection: binding(\.overlayBackground)) {
        Text("Blurred desktop").tag(OverlayBackground.blur)
        Text("Solid").tag(OverlayBackground.solid)
        Text("Image").tag(OverlayBackground.image)
      }
      if controller.currentSettings.overlayBackground == .image {
        HStack {
          Text(
            controller.currentSettings.overlayImagePath.map {
              URL(fileURLWithPath: $0).lastPathComponent
            } ?? "No image chosen — falls back to blur"
          )
          .font(Tokens.Typography.caption)
          .foregroundStyle(Tokens.Color.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
          Spacer()
          Button("Choose…") { pickOverlayImage() }
            .controlSize(.small)
        }
      }
      Toggle("Allow Esc to skip", isOn: binding(\.allowEsc))
        .toggleStyle(.switch)
      Toggle("Chime when a break ends", isOn: binding(\.soundEnabled))
        .toggleStyle(.switch)
    }
    Section("Messages") {
      MessagesEditor(
        messages: controller.currentSettings.messages
      ) { updated in
        controller.updateSettings { $0.messages = updated }
      }
    }
    Section {
      Button("Take a break now") { controller.triggerBreakNow() }
    }
  }

  @ViewBuilder private var nudgesPane: some View {
    Section {
      Toggle("Enable nudges", isOn: binding(\.wellness.enabled))
        .toggleStyle(.switch)
      if controller.currentSettings.wellness.enabled {
        stepperRow(
          "Posture nudge", value: binding(\.wellness.postureMinutes),
          range: GazeKeeperSettings.postureRange, unit: "min")
        stepperRow(
          "Blink nudge", value: binding(\.wellness.blinkMinutes),
          range: GazeKeeperSettings.blinkRange, unit: "min")
        Toggle("Weekly digest on Mondays", isOn: binding(\.wellness.weeklyDigest))
          .toggleStyle(.switch)
      }
    }
    if controller.currentSettings.wellness.enabled {
      Section {
        Toggle("Quiet hours", isOn: binding(\.wellness.quietHours.enabled))
          .toggleStyle(.switch)
        if controller.currentSettings.wellness.quietHours.enabled {
          timeRangeRow(
            label: "Silent window",
            start: { controller.currentSettings.wellness.quietHours.startMinuteOfDay },
            setStart: { m in
              controller.updateSettings { $0.wellness.quietHours.startMinuteOfDay = m }
            },
            end: { controller.currentSettings.wellness.quietHours.endMinuteOfDay },
            setEnd: { m in
              controller.updateSettings { $0.wellness.quietHours.endMinuteOfDay = m }
            },
            a11yStart: "Quiet hours start", a11yEnd: "Quiet hours end")
          Text("Past-midnight windows are supported; nudges pause inside this window.")
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Color.textSecondary)
        }
      }
      Section("Wording") {
        WellnessMessageField(
          title: "Custom posture message",
          storedValue: controller.currentSettings.wellness.postureMessage,
          placeholder: WellnessCadence.defaultPostureBody
        ) { text in
          controller.updateSettings { $0.wellness.postureMessage = text }
        }
        WellnessMessageField(
          title: "Custom blink message",
          storedValue: controller.currentSettings.wellness.blinkMessage,
          placeholder: WellnessCadence.defaultBlinkBody
        ) { text in
          controller.updateSettings { $0.wellness.blinkMessage = text }
        }
      }
    }
  }

  @ViewBuilder private var shortcutsPane: some View {
    Section {
      ShortcutRecorderRow(
        title: "Start break now", action: .startBreak,
        controller: controller,
        failed: failedShortcuts.contains(.startBreak))
      ShortcutRecorderRow(
        title: "Pause / resume breaks", action: .togglePause,
        controller: controller,
        failed: failedShortcuts.contains(.togglePause))
      ShortcutRecorderRow(
        title: "Snooze 5 minutes", action: .snoozeBreak,
        controller: controller,
        failed: failedShortcuts.contains(.snoozeBreak))
    }
  }

  @ViewBuilder private var generalPane: some View {
    Section {
      Toggle("Launch at login", isOn: binding(\.launchAtLogin))
        .toggleStyle(.switch)
      Toggle("Show time in menu bar", isOn: binding(\.menuBarCountdown))
        .toggleStyle(.switch)
      Picker("Accent", selection: binding(\.accentChoice)) {
        Text("GazeKeeper teal").tag(AccentChoice.brand)
        Text("System").tag(AccentChoice.system)
      }
    }
    Section("Your data") {
      Button("Reveal stats & settings folder") {
        NSWorkspace.shared.activateFileViewerSelecting([
          controller.dataDirectoryURL
        ])
      }
      Button("Replay onboarding") {
        controller.updateSettings { $0.hasCompletedOnboarding = false }
      }
    }
  }

  private func pickOverlayImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Choose a break background image"
    if panel.runModal() == .OK, let url = panel.url {
      controller.updateSettings { $0.overlayImagePath = url.path }
    }
  }

  private var statusLine: some View {
    let state = controller.snapshot.state
    let paused = state.isPaused()
    let due = state.effectiveNextDue(from: controller.clock.now())
    return VStack(alignment: .leading, spacing: 4) {
      Text(paused ? "PAUSED" : "NEXT BREAK")
        .font(Tokens.Typography.keyCap)
        .kerning(1)
        .foregroundStyle(paused ? Tokens.Color.warm : Tokens.Color.textTertiary)
      if !paused {
        Text(due, format: .dateTime.hour().minute())
          .font(Tokens.Typography.chart(20))
          .monospacedDigit()
          .foregroundStyle(Tokens.Color.text)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityStatus(paused: paused, due: due))
  }

  private func accessibilityStatus(paused: Bool, due: Date) -> String {
    if paused { return "Scheduling paused" }
    let formatted = due.formatted(date: .omitted, time: .shortened)
    return "Next break at \(formatted)"
  }

  private func binding<T>(
    _ keyPath: WritableKeyPath<GKSettingsV1, T>
  ) -> Binding<T> {
    Binding<T>(
      get: { controller.currentSettings[keyPath: keyPath] },
      set: { newValue in controller.updateSettings { $0[keyPath: keyPath] = newValue } }
    )
  }

  private func stepperRow(
    _ title: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String
  ) -> some View {
    stepperRow(title, value: value, range: range) { "\($0) \(unit)" }
  }

  private func stepperRow(
    _ title: String, value: Binding<Int>, range: ClosedRange<Int>,
    format: (Int) -> String
  ) -> some View {
    Stepper(
      value: value,
      in: range,
      step: 1
    ) {
      HStack {
        Text(title)
        Spacer()
        Text(format(value.wrappedValue))
          .foregroundStyle(Tokens.Color.textSecondary)
          .monospacedDigit()
      }
    }
  }

  private func timeRangeRow(
    label: String,
    start: @escaping () -> Int, setStart: @escaping (Int) -> Void,
    end: @escaping () -> Int, setEnd: @escaping (Int) -> Void,
    a11yStart: String, a11yEnd: String
  ) -> some View {
    HStack(spacing: 8) {
      Text(label)
      Spacer()
      DatePicker(
        "",
        selection: minuteOfDayBinding(minute: start, set: setStart),
        displayedComponents: .hourAndMinute
      )
      .labelsHidden()
      .accessibilityLabel(a11yStart)
      Text("to").foregroundStyle(Tokens.Color.textSecondary)
      DatePicker(
        "",
        selection: minuteOfDayBinding(minute: end, set: setEnd),
        displayedComponents: .hourAndMinute
      )
      .labelsHidden()
      .accessibilityLabel(a11yEnd)
    }
  }

  private func minuteOfDayBinding(
    minute: @escaping () -> Int, set: @escaping (Int) -> Void
  ) -> Binding<Date> {
    Binding<Date>(
      get: { Self.dateFrom(minuteOfDay: minute()) },
      set: { set(Self.minuteOf($0)) }
    )
  }

  private var effectiveSelectedDays: Set<Int> {
    let days = controller.currentSettings.officeHours.days
    return days.isEmpty ? OfficeHoursSettings.allDays : days
  }

  private var dayToggles: some View {
    let selection = effectiveSelectedDays
    return HStack(spacing: 6) {
      ForEach(Array(Self.daySymbols.enumerated()), id: \.offset) { index, symbol in
        let dayNumber = index + 1
        Toggle(
          symbol,
          isOn: Binding<Bool>(
            get: { selection.contains(dayNumber) },
            set: { isOn in
              var updated = selection
              if isOn {
                updated.insert(dayNumber)
              } else {
                updated.remove(dayNumber)
              }
              controller.updateSettings { $0.officeHours.days = updated }
            }
          )
        )
        .toggleStyle(.button)
        .accessibilityLabel(fullDayName(dayNumber))
        .accessibilityHint("Toggles breaks on this weekday")
        .accessibilityValue(selection.contains(dayNumber) ? "breaks active" : "no breaks")
      }
    }
  }

  private func fullDayName(_ number: Int) -> String {
    let names = [
      "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]
    return names[number - 1]
  }

  private func detectorToggle(_ title: String, id: String) -> some View {
    Toggle(
      title,
      isOn: Binding<Bool>(
        get: { controller.currentSettings.detectors[id]?.enabled ?? true },
        set: { newValue in
          controller.updateSettings {
            $0.detectors[id, default: DetectorSettings()].enabled = newValue
          }
        }
      )
    )
    .toggleStyle(.switch)
  }

  private static func dateFrom(minuteOfDay value: Int) -> Date {
    var components = DateComponents()
    components.hour = value / 60
    components.minute = value % 60
    return Calendar.current.date(from: components) ?? Date()
  }

  private static func minuteOf(_ date: Date) -> Int {
    let components = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (components.hour ?? 0) * 60 + (components.minute ?? 0)
  }
}

private struct MessageDraft: Identifiable, Equatable {
  let id: UUID
  var text: String
}

struct WellnessMessageField: View {
  let title: String
  let storedValue: String?
  let placeholder: String
  let onCommit: (String?) -> Void

  @State private var draft: String = ""
  @State private var seededFrom: String?
  @FocusState private var fieldIsFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(Tokens.Typography.body)
      TextField(title, text: $draft, prompt: Text(placeholder), axis: .vertical)
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...3)
        .focused($fieldIsFocused)
        .onSubmit(commit)
        .accessibilityLabel(title)
        .accessibilityValue(draft.isEmpty ? "default message in use" : draft)
      HStack(spacing: 10) {
        Text(hintText)
          .font(Tokens.Typography.caption)
          .foregroundStyle(Tokens.Color.textSecondary)
        if !draft.isEmpty {
          Button("Clear") {
            draft = ""
            commit()
          }
          .buttonStyle(.borderless)
          .font(Tokens.Typography.caption)
          .accessibilityLabel("Clear \(title)")
        }
      }
    }
    .onAppear(perform: reseedIfNeeded)
    .onChange(of: storedValue) { _, _ in reseedIfNeeded() }
  }

  private var hintText: String {
    draft.isEmpty
      ? "Empty uses the default nudge wording. Press Return to save."
      : "Press Return to save."
  }

  private func reseedIfNeeded() {
    guard seededFrom != storedValue else { return }
    if !fieldIsFocused || seededFrom == nil {
      draft = storedValue ?? ""
      seededFrom = storedValue
    }
  }

  private func commit() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    onCommit(trimmed.isEmpty ? nil : trimmed)
  }
}

private struct MessagesEditor: View {
  let messages: [String]
  let onApply: ([String]) -> Void

  @State private var drafts: [MessageDraft] = []
  @State private var committed: [String]?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach($drafts) { $draft in
        HStack(spacing: 8) {
          TextField("Message \(position(of: draft))", text: $draft.text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit { commit() }
            .accessibilityLabel("Break message \(position(of: draft))")
          Button {
            drafts.removeAll { $0.id == draft.id }
            commit()
          } label: {
            Image(systemName: "minus.circle")
              .foregroundStyle(Tokens.Color.textSecondary)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove message \(position(of: draft))")
        }
      }
      HStack(spacing: 12) {
        Button("Add Message") {
          drafts.append(MessageDraft(id: UUID(), text: ""))
          commit()
        }
        .disabled(drafts.count >= GazeKeeperSettings.maxMessages)
        Text("\(drafts.count) of \(GazeKeeperSettings.maxMessages)")
          .font(Tokens.Typography.caption)
          .foregroundStyle(Tokens.Color.textSecondary)
        Text("Press Return to save an edited message")
          .font(Tokens.Typography.caption)
          .foregroundStyle(Tokens.Color.textSecondary)
      }
    }
    .onAppear(perform: reseedIfNeeded)
    .onChange(of: messages) { _, _ in reseedIfNeeded() }
  }

  private func position(of draft: MessageDraft) -> Int {
    drafts.firstIndex { $0.id == draft.id }.map { $0 + 1 } ?? 0
  }

  private func reseedIfNeeded() {
    if committed == nil || committed != messages {
      drafts = messages.map { MessageDraft(id: UUID(), text: $0) }
      committed = messages
    }
  }

  private func commit() {
    let cleaned =
      drafts
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    committed = cleaned
    onApply(cleaned)
  }
}

/// The user's explicit pause/ignore rules — pick a running app, choose
/// whether it pauses the schedule or is exempt from the fullscreen
/// heuristic. Rules match on bundle id, never on the app's name.
private struct AppRulesEditor: View {
  let controller: AppStateController

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("App rules")
          .font(Tokens.Typography.body)
        Spacer()
        Menu {
          ForEach(runningApps, id: \.bundleIdentifier) { app in
            Button(app.localizedName ?? app.bundleIdentifier ?? "Unknown") {
              guard let id = app.bundleIdentifier else { return }
              controller.updateSettings { $0.appRules[id] = .pause }
            }
          }
        } label: {
          Label("Add app", systemImage: "plus")
            .font(Tokens.Typography.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }

      let rules = controller.currentSettings.appRules.sorted { $0.key < $1.key }
      if rules.isEmpty {
        Text("No app rules — hardware signals and fullscreen decide.")
          .font(Tokens.Typography.caption)
          .foregroundStyle(Tokens.Color.textSecondary)
      } else {
        ForEach(rules, id: \.key) { rule in
          HStack {
            Text(displayName(for: rule.key))
              .font(Tokens.Typography.body)
              .foregroundStyle(Tokens.Color.text)
              .lineLimit(1)
            Spacer()
            Picker(
              "",
              selection: Binding<AppRuleAction>(
                get: { rule.value },
                set: { newValue in
                  controller.updateSettings { $0.appRules[rule.key] = newValue }
                })
            ) {
              Text("Pause").tag(AppRuleAction.pause)
              Text("Ignore").tag(AppRuleAction.ignore)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            Button {
              controller.updateSettings { $0.appRules[rule.key] = nil }
            } label: {
              Image(systemName: "minus.circle")
                .foregroundStyle(Tokens.Color.textSecondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove rule for \(displayName(for: rule.key))")
          }
        }
      }
    }
  }

  private var runningApps: [NSRunningApplication] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
      .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
  }

  private func displayName(for bundleId: String) -> String {
    if let app = NSWorkspace.shared.runningApplications.first(where: {
      $0.bundleIdentifier == bundleId
    }), let name = app.localizedName {
      return name
    }
    return bundleId
  }
}

/// The pane list, set as lines on an eye chart: numbered on the left,
/// the current line in the accent with a rule under it.
private struct SettingsRail<Status: View>: View {
  @Environment(\.gkAccent) private var accent: Color
  @Binding var selection: SettingsPane
  let status: Status

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(SettingsPane.allCases.enumerated()), id: \.element) { index, pane in
          let current = pane == selection
          Button {
            selection = pane
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text("\(index + 1)")
                .font(Tokens.Typography.keyCap)
                .foregroundStyle(current ? accent : Tokens.Color.textTertiary)
                .frame(width: 12, alignment: .leading)
              Text(pane.rawValue.uppercased())
                .font(Tokens.Typography.chart(14))
                .kerning(1.2)
                .foregroundStyle(current ? accent : Tokens.Color.text)
            }
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
              (current ? accent : .clear).frame(height: 1)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(pane.rawValue)
          .accessibilityAddTraits(current ? .isSelected : [])
        }
      }
      Spacer()
      status
    }
    .padding(.horizontal, Tokens.Spacing.l)
    .padding(.vertical, Tokens.Spacing.l)
    .frame(width: 212)
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
    .overlay(alignment: .trailing) {
      Tokens.Color.separator.frame(width: 1)
    }
  }
}

/// One half of the rule, set large: the label, the figure in the chart
/// face, and a stepper under it.
private struct RuleFigure: View {
  let title: String
  @Binding var value: Int
  let range: ClosedRange<Int>
  let unit: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(Tokens.Typography.keyCap)
        .kerning(1)
        .foregroundStyle(Tokens.Color.textSecondary)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("\(value)")
          .font(Tokens.Typography.chart(52))
          .monospacedDigit()
          .foregroundStyle(Tokens.Color.text)
          .contentTransition(.numericText())
          .animation(Tokens.Motion.ui, value: value)
        Text(unit.uppercased())
          .font(Tokens.Typography.keyCap)
          .kerning(1)
          .foregroundStyle(Tokens.Color.textSecondary)
        Spacer(minLength: 8)
        Stepper(title, value: $value, in: range)
          .labelsHidden()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.trailing, Tokens.Spacing.l)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityValue("\(value) \(unit)")
  }
}

/// The real break view, drawn small with the current settings. Blur reads
/// against the user's own wallpaper, as it would on screen.
private struct OverlayPreview: View {
  let controller: AppStateController

  private static let canvas = CGSize(width: 1280, height: 800)
  @State private var desktop: NSImage?

  var body: some View {
    let settings = controller.currentSettings
    GeometryReader { proxy in
      let scale = proxy.size.width / Self.canvas.width
      let backdrop = controller.overlayBackgroundResolved
      ZStack {
        if backdrop == .blur { wallpaper }
        OverlayBreakView(
          model: BreakOverlayModel(
            isPresented: true, remainingSeconds: max(1, settings.breakSeconds - 6),
            totalSeconds: settings.breakSeconds,
            message: settings.messages.first ?? GKSettingsV1.defaultMessages[0],
            allowEsc: settings.allowEsc, reduceMotion: true,
            snoozesRemaining: settings.snoozeLimit > 0 ? settings.snoozeLimit : nil),
          reduceMotion: true, showsControls: true,
          background: backdrop,
          onSkip: {}, onPostpone: { _ in })
      }
      .frame(width: Self.canvas.width, height: Self.canvas.height)
      .scaleEffect(scale, anchor: .topLeading)
    }
    .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Preview of the break screen")
    .task {
      guard let screen = NSScreen.main,
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
      else { return }
      desktop = NSImage(contentsOf: url)
    }
  }

  @ViewBuilder private var wallpaper: some View {
    if let desktop {
      Image(nsImage: desktop).resizable().aspectRatio(contentMode: .fill)
    } else {
      LinearGradient(
        colors: [
          Color(nsColor: .systemTeal), Color(nsColor: .systemIndigo),
          Color(nsColor: .systemOrange),
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
  }
}
