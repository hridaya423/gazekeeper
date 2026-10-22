import Foundation

public protocol GKIdleProviding: Sendable {
  func currentIdleSeconds() -> TimeInterval
}

public struct ZeroIdleProvider: GKIdleProviding {
  public init() {}

  public func currentIdleSeconds() -> TimeInterval {
    0
  }
}

public struct FixedIdleProvider: GKIdleProviding {
  private let idleSeconds: TimeInterval

  public init(idleSeconds: TimeInterval) {
    self.idleSeconds = idleSeconds
  }

  public func currentIdleSeconds() -> TimeInterval {
    idleSeconds
  }
}
