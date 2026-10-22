import Foundation

/// Seconds since the last keyboard/mouse input — the "typing lull" that
/// keeps a break from firing mid-keystroke. Platform implementations live
/// in the App layer (`CGEventSource`-backed); tests use `FixedLullProvider`.
public protocol GKInputLullProviding: Sendable {
  func secondsSinceLastInput() -> TimeInterval
}

/// Always reports a deep lull — the default when no provider is wired.
public struct ZeroLullProvider: GKInputLullProviding {
  public init() {}
  public func secondsSinceLastInput() -> TimeInterval { .infinity }
}

public final class FixedLullProvider: GKInputLullProviding, @unchecked Sendable {
  private var lock = NSLock()
  private var seconds: TimeInterval

  public init(seconds: TimeInterval) {
    self.seconds = seconds
  }

  public func set(_ seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    self.seconds = seconds
  }

  public func secondsSinceLastInput() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return seconds
  }
}
