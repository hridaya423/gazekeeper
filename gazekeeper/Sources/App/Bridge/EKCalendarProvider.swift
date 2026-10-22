import EventKit
import Foundation
import GazeKeeperCore

/// EventKit-backed meeting source. A calendar entry counts as a meeting
/// when it carries other people (attendees), a room/link, or a URL —
/// solo focus blocks and reminders do not pull breaks forward.
final class EKCalendarProvider: NSObject, GKCalendarProviding, @unchecked Sendable {
  private let store = EKEventStore()
  private let lock = NSLock()
  private var authorized = false
  private var _onChange: (@Sendable () -> Void)?

  var onChange: (@Sendable () -> Void)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _onChange
    }
    set {
      lock.lock()
      _onChange = newValue
    }
  }

  override init() {
    super.init()
    authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    NotificationCenter.default.addObserver(
      self, selector: #selector(storeChanged),
      name: .EKEventStoreChanged, object: store)
  }

  @objc private func storeChanged() {
    onChange?()
  }

  /// Ask once; the answer is delivered via `completion` on an arbitrary
  /// queue. Declined access stays declined — the OS won't re-prompt.
  func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
    store.requestFullAccessToEvents { [weak self] granted, _ in
      self?.lock.lock()
      self?.authorized = granted
      self?.lock.unlock()
      completion(granted)
    }
  }

  var isAuthorized: Bool {
    lock.lock()
    defer { lock.unlock() }
    return authorized
  }

  /// Re-check TCC state — the user may have flipped it in System
  /// Settings while we were running.
  func refreshAuthorization() {
    lock.lock()
    authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    lock.unlock()
  }

  func upcomingMeetingStarts(within horizon: TimeInterval, from now: Date) -> [Date] {
    guard isAuthorized else { return [] }
    let predicate = store.predicateForEvents(
      withStart: now, end: now.addingTimeInterval(horizon), calendars: nil)
    return store.events(matching: predicate)
      .filter { !$0.isAllDay && Self.isMeeting($0) }
      .map(\.startDate)
      .sorted()
  }

  private static func isMeeting(_ event: EKEvent) -> Bool {
    if let attendees = event.attendees, attendees.count > 1 { return true }
    if let location = event.location, !location.isEmpty { return true }
    if event.url != nil { return true }
    return false
  }
}
