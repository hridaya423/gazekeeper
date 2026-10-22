import XCTest

@testable import GazeKeeperCore

final class SettingsStoreLiveApplyTests: XCTestCase {

  func testUpdateSettingsWhileIdleRecomputesNextDueImmediately() {
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    var settings = GKSettingsV1()
    settings.intervalMinutes = 20
    let scheduler = Scheduler(settings: settings, now: epoch)

    var faster = GKSettingsV1()
    faster.intervalMinutes = 5
    scheduler.updateSettings(faster, at: epoch.addingTimeInterval(30))

    let state = scheduler.currentState()
    XCTAssertEqual(state.phase, .idle)
    XCTAssertEqual(
      state.nextDue.timeIntervalSince(epoch.addingTimeInterval(30)), 5 * 60, accuracy: 0.001)

    let afterTick = scheduler.tick(epoch.addingTimeInterval(31))
    XCTAssertEqual(scheduler.currentState().phase, .idle)
    XCTAssertEqual(
      scheduler.currentState().nextDue.timeIntervalSince(epoch.addingTimeInterval(31)),
      5 * 60 - 1,
      accuracy: 0.001
    )
    XCTAssertTrue(afterTick.isEmpty)
  }

  func testUpdateSettingsMidBreakKeepsBreakWindowAndAnchorsNextDueAfterEnd() {
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    var settings = GKSettingsV1()
    settings.intervalMinutes = 20
    settings.breakSeconds = 20
    let scheduler = Scheduler(settings: settings, now: epoch)

    _ = scheduler.triggerBreak(at: epoch)
    var longer = GKSettingsV1()
    longer.intervalMinutes = 45
    longer.breakSeconds = 20
    scheduler.updateSettings(longer, at: epoch.addingTimeInterval(10))

    let midBreak = scheduler.currentState()
    XCTAssertEqual(midBreak.phase, .breaking)
    XCTAssertEqual(
      midBreak.breakEndsAt?.timeIntervalSince(epoch) ?? -1, 20, accuracy: 0.001)

    _ = scheduler.tick(epoch.addingTimeInterval(21))
    XCTAssertEqual(scheduler.currentState().phase, .cooldown)
    XCTAssertEqual(
      scheduler.currentState().nextDue.timeIntervalSince(epoch),
      21 + 45 * 60,
      accuracy: 0.001
    )
  }
}
