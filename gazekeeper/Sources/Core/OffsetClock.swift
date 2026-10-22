import Foundation

public struct OffsetClock: GKClock, @unchecked Sendable {
  private let base: any GKClock
  private let state = OffsetClockState()

  public init(base: any GKClock = SystemClock()) {
    self.base = base
  }

  public init(offset seconds: TimeInterval, base: any GKClock = SystemClock()) {
    self.base = base
    self.state.storeOffset(seconds)
  }

  public func setOffset(_ seconds: TimeInterval) {
    state.storeOffset(seconds)
  }

  public func now() -> Date {
    base.now().addingTimeInterval(state.loadOffset())
  }

  public func shiftOffset(bySeconds seconds: TimeInterval) {
    state.storeOffset(state.loadOffset() + seconds)
  }
}

private final class OffsetClockState: @unchecked Sendable {
  private let lock = NSLock()
  private var offset: TimeInterval = 0

  func loadOffset() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return offset
  }

  func storeOffset(_ value: TimeInterval) {
    lock.lock()
    offset = value
    lock.unlock()
  }
}
