import Foundation

public struct DailyScorePoint: Equatable, Sendable {
  public let date: Date
  public let score: ScreenScore
}

public struct ScreenScore: Equatable, Sendable {

  public static let disciplineMaximum = 60
  public static let adherenceMaximum = 40
  public static let overduePenaltyPerMinute = 2
  public static let skipBasePenalty = 4
  public static let postponePenalty = 2
  public static let skipExtraPenalty = skipBasePenalty - postponePenalty

  public let discipline: Int
  public let adherence: Int
  public let disciplineRaw: Int
  public let breaksDue: Int
  public let breaksTaken: Int
  public let breaksSkipped: Int
  public let breaksPostponed: Int
  /// Breaks the overlay completed but the user typed through — resolved
  /// dues that were never rest.
  public let breaksWorked: Int

  public init(
    discipline: Int, adherence: Int, disciplineRaw: Int,
    breaksDue: Int, breaksTaken: Int, breaksSkipped: Int, breaksPostponed: Int,
    breaksWorked: Int = 0
  ) {
    self.discipline = min(max(discipline, 0), Self.disciplineMaximum)
    self.adherence = min(max(adherence, 0), Self.adherenceMaximum)
    self.disciplineRaw = disciplineRaw
    self.breaksDue = breaksDue
    self.breaksTaken = breaksTaken
    self.breaksSkipped = breaksSkipped
    self.breaksPostponed = breaksPostponed
    self.breaksWorked = breaksWorked
  }

  public static func empty() -> ScreenScore {
    ScreenScore(
      discipline: 0, adherence: 0, disciplineRaw: 0,
      breaksDue: 0, breaksTaken: 0, breaksSkipped: 0, breaksPostponed: 0)
  }

  /// True when the day produced no break activity worth scoring. A session
  /// with zero dues is not a perfect day; it is no day at all.
  public var isEmpty: Bool {
    breaksDue == 0 && breaksTaken == 0 && breaksSkipped == 0 && breaksWorked == 0
  }

  public var total: Int {
    min(Self.disciplineMaximum + Self.adherenceMaximum, discipline + adherence)
  }

  public static func penalty(for kind: BreakEventKind) -> Int {
    switch kind {
    case .breakSkipped:
      return skipBasePenalty
    case .breakPostponed:
      return postponePenalty
    default:
      return 0
    }
  }

  private struct SessionRecord {
    var start: Date
    var end: Date?
  }

  private struct DueRecord {
    var dueAt: Date
    var resolvedAt: Date?
    /// True when the resolution carries an overdue cost (skip, postpone, or a
    /// due left hanging). Starting or taking the break is always free: that is
    /// the product doing its job, not the user being slow.
    var penalized = false
    var sessionIndex: Int?
  }

  public static func score(
    events: [LoggedEvent], dayBucket: Date,
    calendar: Calendar = .current, now: Date? = nil
  ) -> ScreenScore {
    let effectiveNow = now ?? Date()
    var dueCount = 0
    var takenCount = 0
    var skippedCount = 0
    var postponedCount = 0
    var workedCount = 0
    var sessions: [SessionRecord] = []
    var dues: [DueRecord] = []
    var openSessionIndex: Int?
    var breakInProgress = false

    /// Only dues from the currently open session can resolve. A due left
    /// hanging when its session ends keeps its overdue cost — a relaunched
    /// break does not retroactively excuse it.
    func resolveLatestOpenDue(at resolution: Date, penalized: Bool) -> Bool {
      for index in dues.indices.reversed()
      where dues[index].resolvedAt == nil && dues[index].sessionIndex == openSessionIndex {
        dues[index].resolvedAt = resolution
        dues[index].penalized = penalized
        return true
      }
      return false
    }

    for event in events where calendar.isDate(event.at, inSameDayAs: dayBucket) {
      // Postponements the user never asked for (away, outside the schedule)
      // stay out of the score.
      switch (event.reason == "idle" || event.reason == "office_hours")
        && event.kind == .breakPostponed
        || (event.reason == "skipped_ahead" && event.kind == .breakSkipped)
        ? nil : event.kind
      {
      case .sessionStarted:
        if openSessionIndex == nil {
          sessions.append(SessionRecord(start: event.at))
          openSessionIndex = sessions.count - 1
        }
      case .sessionEnded:
        if let index = openSessionIndex {
          sessions[index].end = event.at
        }
        openSessionIndex = nil
      case .breakDue:
        dueCount += 1
        dues.append(
          DueRecord(dueAt: event.at, sessionIndex: openSessionIndex))
      case .breakStarted:
        // A break that starts with no due is a voluntary break: it earns an
        // adherence credit as its own due, resolved immediately and for free.
        if !resolveLatestOpenDue(at: event.at, penalized: false) {
          dueCount += 1
          dues.append(
            DueRecord(
              dueAt: event.at, resolvedAt: event.at, sessionIndex: openSessionIndex))
        }
        breakInProgress = true
      case .naturalBreak:
        // A real rest the machine observed (away, locked, deep idle): it
        // counts like a taken break and resolves any open due for free.
        takenCount += 1
        _ = resolveLatestOpenDue(at: event.at, penalized: false)
        breakInProgress = false
      case .breakTaken:
        takenCount += 1
        if resolveLatestOpenDue(at: event.at, penalized: false) {
          // Resolved a due that was still open.
        } else if !breakInProgress {
          // A bare take with no start and no due still records a break.
          dueCount += 1
          dues.append(
            DueRecord(
              dueAt: event.at, resolvedAt: event.at, sessionIndex: openSessionIndex))
        }
        breakInProgress = false
      case .breakWorked:
        // Worked through: the due resolves without penalty — no skip, no
        // postponement — but it does not add to takenCount, so adherence
        // reflects rest that actually happened.
        workedCount += 1
        _ = resolveLatestOpenDue(at: event.at, penalized: false)
        breakInProgress = false
      case .breakSkipped:
        skippedCount += 1
        _ = resolveLatestOpenDue(at: event.at, penalized: true)
        breakInProgress = false
      case .breakPostponed:
        postponedCount += 1
        _ = resolveLatestOpenDue(at: event.at, penalized: true)
        breakInProgress = false
      case .breakInterrupted:
        // An interrupted break was already credited by its start; the
        // interrupt itself is the system's doing, not the user's.
        breakInProgress = false
      case .detectorPaused, .detectorResumed, .nudgeSent, .menuRevealed,
        .snoozeExhausted, nil:
        break
      }
    }

    var overdueMinutesTotal = 0
    for due in dues {
      let anchor: Date?
      if let resolved = due.resolvedAt {
        anchor = due.penalized ? resolved : nil
      } else if let sessionIndex = due.sessionIndex, let end = sessions[sessionIndex].end {
        anchor = end
      } else {
        anchor = min(effectiveNow, endOfDay(dayBucket, calendar))
      }
      guard let anchor else { continue }
      overdueMinutesTotal += overdueMinutes(due: due.dueAt, until: anchor)
    }
    let disciplineRaw =
      dueCount == 0
      ? 0
      : max(0, disciplineMaximum - overduePenaltyPerMinute * overdueMinutesTotal)
    let discipline = clampComponent(disciplineRaw, maximum: disciplineMaximum)

    var adherence = 0
    if dueCount > 0 {
      let takenBase = Int(
        (Double(min(takenCount, dueCount)) / Double(dueCount)
          * Double(adherenceMaximum))
          .rounded(.down))
      let penaltyLoad = min(
        adherenceMaximum,
        skippedCount * penalty(for: .breakSkipped)
          + postponedCount * penalty(for: .breakPostponed))
      adherence = clampComponent(takenBase - penaltyLoad, maximum: adherenceMaximum)
    }

    return ScreenScore(
      discipline: discipline, adherence: adherence, disciplineRaw: disciplineRaw,
      breaksDue: dueCount, breaksTaken: takenCount, breaksSkipped: skippedCount,
      breaksPostponed: postponedCount, breaksWorked: workedCount)
  }

  static func clampComponent(_ value: Int, maximum: Int) -> Int {
    min(max(value, 0), maximum)
  }

  static func overdueMinutes(due: Date, until end: Date) -> Int {
    guard end > due else { return 0 }
    return Int(end.timeIntervalSince(due) / 60)
  }

  private static func endOfDay(_ date: Date, _ calendar: Calendar) -> Date {
    guard
      let startOfNextDay = calendar.date(
        byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    else { return date }
    return startOfNextDay.addingTimeInterval(-60)
  }

  /// Consecutive days, counted back from the most recent point in `series`,
  /// that recorded at least one taken break. A day where no break was ever
  /// due (a day off under office hours) is skipped rather than breaking the
  /// run; a due day with zero taken breaks ends it. When `today` is provided,
  /// a still-running day with dues but no takes is skipped too — it has not
  /// broken the run yet.
  public static func streak(
    series: [DailyScorePoint], today: Date? = nil, calendar: Calendar = .current
  ) -> Int {
    var count = 0
    for point in series.reversed() {
      if point.score.breaksTaken > 0 {
        count += 1
      } else if point.score.breaksDue > 0 {
        if let today, calendar.isDate(point.date, inSameDayAs: today) { continue }
        break
      }
    }
    return count
  }

  public static func dailySeries(
    events: [LoggedEvent], endingAt: Date, days: Int,
    calendar: Calendar = .current, now: Date? = nil
  ) -> [DailyScorePoint] {
    var series: [DailyScorePoint] = []
    for offset in stride(from: days - 1, through: 0, by: -1) {
      guard let bucket = calendar.date(byAdding: .day, value: -offset, to: endingAt) else {
        continue
      }
      let dayStart = calendar.startOfDay(for: bucket)
      series.append(
        DailyScorePoint(
          date: dayStart,
          score: score(events: events, dayBucket: dayStart, calendar: calendar, now: now)))
    }
    return series
  }
}
