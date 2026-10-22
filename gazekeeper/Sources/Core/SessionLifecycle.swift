import Foundation

public protocol SessionTerminating: AnyObject, Sendable {
  @MainActor
  func terminate()
}

@MainActor
public final class SessionLifecycleController {
  let clock: OffsetClock
  private let terminator: (any SessionTerminating)?
  private var didEndSession = false

  public init(clock: OffsetClock, terminator: (any SessionTerminating)? = nil) {
    self.clock = clock
    self.terminator = terminator
  }

  public func endSession(on log: EventLog, reason: String = "quit") {
    guard !didEndSession else { return }
    didEndSession = true
    log.append(
      LoggedEvent(kind: BreakEventKind.sessionEnded, reason: reason, at: clock.now()))
  }

  public func quitAfterFlush(persistingWith persist: () -> Void, on log: EventLog) {
    persist()
    endSession(on: log)
    terminator?.terminate()
  }

  var hasEndedSession: Bool { didEndSession }
}
