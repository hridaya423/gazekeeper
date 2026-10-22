import Foundation

/// The weekly digest's two pure halves: when it may be delivered (Monday
/// 09:00 local, same-day only — a missed Monday is skipped, not fired
/// late on Tuesday) and what it says (last week's rest, summarized).
public enum WeeklyDigest {

  /// Next Monday 09:00 local on or after `from`. On a Monday already past
  /// 09:00 the due is that same morning — i.e., already elapsed, so the
  /// cadence fires at its next tick today. Scheduling the *following*
  /// delivery after a fire must call this with tomorrow's date.
  public static func nextDelivery(from: Date, calendar: Calendar) -> Date {
    let startOfToday = calendar.startOfDay(for: from)
    return calendar.nextDate(
      after: startOfToday.addingTimeInterval(-1),
      matching: DateComponents(hour: 9, minute: 0, weekday: 2),
      matchingPolicy: .nextTime
    ) ?? from.addingTimeInterval(7 * 86_400)
  }

  /// "Last week: N taken, N skipped, N worked through — avg score N."
  /// Nil when last week has no dues at all: an empty week earns no toast.
  public static func body(
    events: [LoggedEvent], now: Date, calendar: Calendar
  ) -> String? {
    guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
    else { return nil }
    let points = ScreenScore.dailySeries(
      events: events, endingAt: weekStart.addingTimeInterval(-1), days: 7,
      calendar: calendar, now: now)
    let days = points.map(\.score)
    let dues = days.reduce(0) { $0 + $1.breaksDue }
    guard dues > 0 else { return nil }
    let taken = days.reduce(0) { $0 + $1.breaksTaken }
    let skipped = days.reduce(0) { $0 + $1.breaksSkipped }
    let worked = days.reduce(0) { $0 + $1.breaksWorked }
    let scored = days.filter { !$0.isEmpty }
    let average = scored.isEmpty ? 0 : scored.reduce(0) { $0 + $1.total } / scored.count
    return
      "Last week: \(taken) taken, \(skipped) skipped, \(worked) worked through — avg score \(average)."
  }
}
