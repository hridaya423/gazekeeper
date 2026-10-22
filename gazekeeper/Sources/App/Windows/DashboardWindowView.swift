import GazeKeeperCore
import SwiftUI

/// A row of optician's ticks — the same mark as the break dial, laid flat.
/// `lit` ticks from the leading edge take the tint, the rest stay faint.
struct TickRuler: View {
  let count: Int
  let lit: Int
  let tint: Color
  var height: CGFloat = 10

  var body: some View {
    HStack(spacing: 0) {
      ForEach(0..<count, id: \.self) { index in
        Capsule()
          .fill(index < lit ? tint : Tokens.Color.separator)
          .frame(width: 2, height: height)
          .frame(maxWidth: .infinity)
      }
    }
    .accessibilityHidden(true)
  }
}

/// A small caps label in the chart face's companion mono, used as the
/// eyebrow over every section.
private struct Eyebrow: View {
  let text: String
  var tint: Color = Tokens.Color.textSecondary

  var body: some View {
    Text(text.uppercased())
      .font(Tokens.Typography.keyCap)
      .kerning(1)
      .foregroundStyle(tint)
  }
}

private struct NextBreakSection: View {
  @Environment(\.gkAccent) private var accent: Color
  let controller: AppStateController

  private static let ticks = 40

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let state = controller.snapshot.state
      let paused = state.isPaused()
      VStack(alignment: .leading, spacing: 14) {
        Eyebrow(text: statusLabel(state), tint: paused ? Tokens.Color.warm : accent)
        Text(clockText(state, at: context.date))
          .font(Tokens.Typography.chart(72))
          .monospacedDigit()
          .foregroundStyle(paused ? Tokens.Color.textSecondary : Tokens.Color.text)
        TickRuler(
          count: Self.ticks,
          lit: Int((remainingShare(state, at: context.date) * Double(Self.ticks)).rounded(.up)),
          tint: paused ? Tokens.Color.textTertiary : accent, height: 14)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(statusLabel(state))
      .accessibilityValue(clockText(state, at: context.date))
    }
  }

  private func statusLabel(_ state: SchedulerState) -> String {
    if state.isPaused() { return state.pausedByUser ? "Paused by you" : "Paused automatically" }
    switch state.phase {
    case .breaking: return "On a break"
    case .headsUp: return "Break starting"
    default: return "Next break in"
    }
  }

  private func clockText(_ state: SchedulerState, at date: Date) -> String {
    if state.phase == .breaking {
      return AppStateController.format(controller.breakRemainingRounded)
    }
    return AppStateController.format(Int(max(0, ceil(state.effectiveRemaining(from: date)))))
  }

  private func remainingShare(_ state: SchedulerState, at date: Date) -> Double {
    if state.phase == .breaking { return 0 }
    let interval = Double(controller.currentSettings.intervalMinutes * 60)
    guard interval > 0 else { return 0 }
    return min(1, max(0, state.effectiveRemaining(from: date) / interval))
  }
}

private struct TodaySection: View {
  @Environment(\.gkAccent) private var accent: Color
  let score: ScreenScore
  let date: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 6) {
        Eyebrow(text: "Today · " + date.formatted(.dateTime.weekday(.wide).day().month()))
        ScoreExplainer()
      }
      HStack(alignment: .top, spacing: 28) {
        VStack(alignment: .leading, spacing: 2) {
          Text(score.isEmpty ? "—" : "\(score.total)")
            .font(Tokens.Typography.chart(88))
            .monospacedDigit()
            .foregroundStyle(score.isEmpty ? Tokens.Color.textTertiary : Tokens.Color.text)
            .contentTransition(.numericText())
            .animation(Tokens.Motion.ui, value: score.total)
          Text("OF 100")
            .font(Tokens.Typography.keyCap)
            .kerning(1)
            .foregroundStyle(Tokens.Color.textTertiary)
        }
        .frame(minWidth: 112, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Screen score today")
        .accessibilityValue(score.isEmpty ? "No score yet" : "\(score.total) of 100")

        VStack(alignment: .leading, spacing: 14) {
          Text(headline)
            .font(Tokens.Typography.title)
            .foregroundStyle(Tokens.Color.text)
          if score.isEmpty {
            Text("Your score appears after the first break of the day.")
              .font(Tokens.Typography.body)
              .foregroundStyle(Tokens.Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            meter("Discipline", score.discipline, ScreenScore.disciplineMaximum)
            meter("Adherence", score.adherence, ScreenScore.adherenceMaximum)
          }
        }
        .padding(.top, 10)
      }

      HStack(alignment: .firstTextBaseline, spacing: 0) {
        count(score.breaksTaken, "taken", tint: accent)
        count(score.breaksPostponed, "snoozed")
        count(score.breaksSkipped, "skipped")
        count(score.breaksWorked, "worked through")
      }
    }
  }

  private var headline: String {
    if score.isEmpty { return "No breaks yet" }
    return score.total >= 70 ? "Strong day" : score.total >= 40 ? "Holding up" : "Room to rest"
  }

  private func meter(_ title: String, _ value: Int, _ maximum: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Eyebrow(text: title)
        Spacer()
        Text("\(value)/\(maximum)")
          .font(Tokens.Typography.keyCap)
          .foregroundStyle(Tokens.Color.text)
      }
      TickRuler(
        count: 20, lit: maximum > 0 ? Int((Double(value) / Double(maximum) * 20).rounded()) : 0,
        tint: accent)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue("\(value) of \(maximum)")
  }

  private func count(_ value: Int, _ label: String, tint: Color = Tokens.Color.text) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(value)")
        .font(Tokens.Typography.chart(28))
        .monospacedDigit()
        .foregroundStyle(value == 0 ? Tokens.Color.textTertiary : tint)
        .contentTransition(.numericText())
        .animation(Tokens.Motion.ui, value: value)
      Text(label)
        .font(Tokens.Typography.caption)
        .foregroundStyle(Tokens.Color.textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue("\(value)")
  }
}

/// Breaks per day as stacked ticks, one tick per break: taken at the
/// base in the accent, snoozed above it, skipped on top in warm.
private struct HistorySection: View {
  @Environment(\.gkAccent) private var accent: Color
  let series: [DailyScorePoint]
  let today: Date

  @State private var range = 7

  private var days: [DailyScorePoint] { Array(series.suffix(range)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Eyebrow(text: range == 7 ? "Last 7 days" : "Last 30 days")
        Spacer()
        Picker("Range", selection: $range) {
          Text("Week").tag(7)
          Text("Month").tag(30)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
      }

      let peak = max(6, days.map { total($0.score) }.max() ?? 0)
      HStack(alignment: .bottom, spacing: range == 7 ? 12 : 3) {
        ForEach(days, id: \.date) { day in
          column(day, peak: peak)
        }
      }
      .frame(height: 150)

      HStack(spacing: 16) {
        legend("Taken", accent)
        legend("Snoozed", Tokens.Color.textTertiary)
        legend("Skipped", Tokens.Color.warm)
      }
    }
  }

  private func total(_ score: ScreenScore) -> Int {
    score.breaksTaken + score.breaksPostponed + score.breaksSkipped
  }

  private func column(_ day: DailyScorePoint, peak: Int) -> some View {
    let isToday = Calendar.current.isDate(day.date, inSameDayAs: today)
    let marks =
      Array(repeating: Tokens.Color.warm, count: day.score.breaksSkipped)
      + Array(repeating: Tokens.Color.textTertiary, count: day.score.breaksPostponed)
      + Array(repeating: accent, count: day.score.breaksTaken)
    return VStack(spacing: 6) {
      GeometryReader { proxy in
        let pitch = proxy.size.height / CGFloat(peak)
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          ForEach(Array(marks.enumerated()), id: \.offset) { _, color in
            Capsule()
              .fill(color)
              .frame(height: max(1.5, pitch * 0.55))
              .frame(height: pitch)
          }
          Tokens.Color.separator.frame(height: 1)
        }
      }
      Text(label(day.date))
        .font(Tokens.Typography.keyCap)
        .foregroundStyle(isToday ? accent : Tokens.Color.textTertiary)
        .frame(height: 12)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).day().month()))
    .accessibilityValue(
      "\(day.score.breaksTaken) taken, \(day.score.breaksPostponed) snoozed, \(day.score.breaksSkipped) skipped"
    )
  }

  private func label(_ date: Date) -> String {
    if range == 7 { return date.formatted(.dateTime.weekday(.narrow)).uppercased() }
    let day = Calendar.current.component(.day, from: date)
    return Calendar.current.isDate(date, inSameDayAs: today) || day % 5 == 0 ? "\(day)" : ""
  }

  private func legend(_ title: String, _ color: Color) -> some View {
    HStack(spacing: 6) {
      Capsule().fill(color).frame(width: 10, height: 2)
      Text(title)
        .font(Tokens.Typography.caption)
        .foregroundStyle(Tokens.Color.textSecondary)
    }
  }
}

private struct WeekSummary: View {
  let series: [DailyScorePoint]
  let today: Date

  private var breaksThisWeek: Int {
    series.suffix(7).map(\.score.breaksTaken).reduce(0, +)
  }

  /// Averages only days that produced a score — a day with no dues is not a
  /// zero, it is no data, and must not drag the average down.
  private var averageScoreText: String {
    let scored = series.suffix(7).map(\.score).filter { !$0.isEmpty }
    guard !scored.isEmpty else { return "—" }
    return "\(scored.map(\.total).reduce(0, +) / scored.count)"
  }

  private var streak: Int {
    ScreenScore.streak(series: series, today: today)
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      item("\(streak)", "day streak")
      item("\(breaksThisWeek)", "breaks this week")
      item(averageScoreText, "average score")
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(streak) day streak, \(breaksThisWeek) breaks this week, average score \(averageScoreText)")
  }

  private func item(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(value)
        .font(Tokens.Typography.chart(28))
        .monospacedDigit()
        .foregroundStyle(Tokens.Color.text)
      Text(label)
        .font(Tokens.Typography.caption)
        .foregroundStyle(Tokens.Color.textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ScoreExplainer: View {
  @State private var shown = false

  var body: some View {
    Button {
      shown.toggle()
    } label: {
      Image(systemName: "info.circle")
        .font(Tokens.Icon.small)
        .foregroundStyle(Tokens.Color.textTertiary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("How the score works")
    .popover(isPresented: $shown, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 10) {
        Text("How the score works").font(Tokens.Typography.headline)
        Text(
          "Discipline, up to \(ScreenScore.disciplineMaximum): starts full and loses \(ScreenScore.overduePenaltyPerMinute) points for every minute a break runs late."
        )
        Text(
          "Adherence, up to \(ScreenScore.adherenceMaximum): the share of due breaks you took, minus \(ScreenScore.skipBasePenalty) per skip and \(ScreenScore.postponePenalty) per snooze."
        )
        Text("A day with no breaks due has no score, not a zero.")
          .foregroundStyle(Tokens.Color.textSecondary)
      }
      .font(Tokens.Typography.body)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: 280)
      .padding(Tokens.Spacing.m)
    }
  }
}

/// Quiet advice — evidence first, Apply/Dismiss on the same line.
/// Only rendered when `CadenceAdvisor` has earned a suggestion.
private struct SuggestionNote: View {
  @Environment(\.gkAccent) private var accent: Color
  let suggestion: CadenceSuggestion
  let currentMinutes: Int
  let onApply: () -> Void
  let onDismiss: () -> Void

  private var message: String {
    let percent = Int((suggestion.missedFraction * 100).rounded())
    switch suggestion.kind {
    case .longerInterval(let minutes):
      return "You've let \(percent)% of breaks slip at \(currentMinutes) min. Try \(minutes)?"
    case .addLongBreaks:
      return "You've let \(percent)% of breaks slip. Add a long break every few?"
    }
  }

  private var applyLabel: String {
    switch suggestion.kind {
    case .longerInterval(let minutes): return "Switch to \(minutes) min"
    case .addLongBreaks: return "Enable long breaks"
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      accent.frame(width: 2)
      VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
        Eyebrow(text: "Cadence check", tint: accent)
        Text(message)
          .font(Tokens.Typography.body)
          .foregroundStyle(Tokens.Color.text)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: Tokens.Spacing.xs) {
          Button(applyLabel, action: onApply)
          Button("Dismiss", action: onDismiss)
            .foregroundStyle(Tokens.Color.textSecondary)
        }
        .controlSize(.small)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Cadence suggestion")
  }
}

struct DashboardWindowView: View {
  let controller: AppStateController

  var body: some View {
    let _ = controller.statsRevision
    let today = controller.clock.now()
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        NextBreakSection(controller: controller)
        rule
        TodaySection(score: controller.todayScore, date: today)
        if let suggestion = controller.cadenceSuggestion {
          SuggestionNote(
            suggestion: suggestion,
            currentMinutes: controller.currentSettings.intervalMinutes,
            onApply: { controller.applyCadenceSuggestion(suggestion) },
            onDismiss: { controller.dismissCadenceSuggestion(suggestion) })
        }
        rule
        HistorySection(series: controller.scoreSeries, today: today)
        rule
        WeekSummary(series: controller.scoreSeries, today: today)
      }
      .padding(.horizontal, Tokens.Spacing.xl)
      .padding(.vertical, Tokens.Spacing.l)
    }
    .background(Tokens.Color.windowBackground)
    .navigationTitle("Dashboard")
    .overlay(alignment: .topTrailing) {
      Menu {
        ForEach(StatsExporter.Format.allCases, id: \.self) { format in
          Button("\(format.label)…") {
            controller.exportStats(format: format)
          }
        }
      } label: {
        Label("Export", systemImage: "square.and.arrow.up")
          .labelStyle(.iconOnly)
          .font(Tokens.Icon.row)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .padding(.top, Tokens.Spacing.l)
      .padding(.trailing, Tokens.Spacing.xl)
      .accessibilityLabel("Export stats")
    }
    .gkAccent(from: controller.currentSettings)
  }

  private var rule: some View {
    Tokens.Color.separator.frame(height: 1)
  }
}
