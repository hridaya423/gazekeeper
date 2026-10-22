import XCTest

@testable import GazeKeeperCore

final class TerminatingSpy: SessionTerminating {
  @MainActor
  private(set) var terminateCallCount = 0

  @MainActor
  var didTerminate: Bool { terminateCallCount > 0 }

  @MainActor
  func terminate() {
    terminateCallCount += 1
  }
}

@MainActor
final class AppStateControllerCoreTests: XCTestCase {

  private func makeLog() -> (EventLog, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("gk-session-tests-\(UUID().uuidString)")
    let log = EventLog(directory: directory)
    log.loadFromDisk()
    return (log, directory)
  }

  private func kinds(_ log: EventLog) -> [String] {
    log.entries.map(\.kind.rawValue)
  }

  func testEndSessionAppendsSessionEndedAtInjectedClockTime() {
    let (log, directory) = makeLog()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = OffsetClock()
    let controller = SessionLifecycleController(clock: clock)

    let before = clock.now().addingTimeInterval(-5)
    controller.endSession(on: log)

    XCTAssertEqual(kinds(log).last, BreakEventKind.sessionEnded.rawValue)
    let ended = log.entries.last!
    XCTAssertGreaterThanOrEqual(ended.at, before)
    XCTAssertTrue(
      ended.at <= clock.now() + 0.001,
      "session_ended anchors at the injected clock's current instant")
    XCTAssertEqual(ended.reason, "quit")
  }

  func testQuitPathEmitsEndedThenTerminatesExactlyOnce() {
    let (log, directory) = makeLog()
    defer { try? FileManager.default.removeItem(at: directory) }
    log.append(LoggedEvent(kind: .sessionStarted, reason: "boot", at: OffsetClock().now()))
    let terminator = TerminatingSpy()
    let controller = SessionLifecycleController(clock: OffsetClock(), terminator: terminator)

    controller.quitAfterFlush(persistingWith: {}, on: log)

    XCTAssertEqual(kinds(log).suffix(2), ["session_started", "session_ended"])
    XCTAssertTrue(terminator.didTerminate)
    XCTAssertEqual(terminator.terminateCallCount, 1)
  }

  func testEndSessionIsSafeWhenNoSessionWasOpened() {
    let (log, directory) = makeLog()
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = SessionLifecycleController(clock: OffsetClock())

    controller.endSession(on: log)

    XCTAssertEqual(kinds(log), ["session_ended"])
  }

  func testSecondInstanceExitAlsoAnchorsSessionAtQuit() {
    let (log, directory) = makeLog()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = OffsetClock()
    let controller = SessionLifecycleController(clock: clock)

    controller.endSession(on: log, reason: "second_instance_exit")

    XCTAssertEqual(kinds(log).last, BreakEventKind.sessionEnded.rawValue)
    XCTAssertEqual(log.entries.last?.reason, "second_instance_exit")
    XCTAssertEqual(
      log.entries.last!.at.timeIntervalSince(clock.now()), 0, accuracy: 0.5,
      "session_ended anchors at the injected clock's current instant")
  }
}
