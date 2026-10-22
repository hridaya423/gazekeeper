import Foundation

public protocol GKClock: Sendable {
  func now() -> Date
}

public struct SystemClock: GKClock {
  public init() {}

  public func now() -> Date {
    Date()
  }
}
