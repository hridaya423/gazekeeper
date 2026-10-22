import Foundation

/// Meeting-start times the schedule should route around. The platform
/// implementation (EventKit) decides what counts as a meeting; the engine
/// only consumes ascending start dates. Tests push fixed intervals.
public protocol GKCalendarProviding: Sendable {
  /// Ascending meeting starts within `horizon` seconds of `now`. Empty
  /// when access is denied or nothing is scheduled — callers treat both
  /// identically.
  func upcomingMeetingStarts(within horizon: TimeInterval, from now: Date) -> [Date]
}
