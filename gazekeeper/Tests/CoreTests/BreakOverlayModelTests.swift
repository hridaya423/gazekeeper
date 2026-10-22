import XCTest

@testable import GazeKeeperCore

final class BreakOverlayModelTests: XCTestCase {

  private func makeDate() -> Date {
    Date(timeIntervalSince1970: 10_000)
  }

  private func breakingState(now: Date, remaining: TimeInterval, total: Int) -> SchedulerState {
    var state = SchedulerState(
      phase: .breaking,
      phaseStartedAt: now,
      nextDue: now.addingTimeInterval(Double(total) + 120)
    )
    state.breakEndsAt = now.addingTimeInterval(remaining)
    return state
  }

  private func makeModel(
    state: SchedulerState,
    settings: GKSettingsV1 = GKSettingsV1(),
    reduceMotion: Bool = false,
    now: Date
  ) -> BreakOverlayModel {
    BreakOverlayModel.make(state: state, settings: settings, reduceMotion: reduceMotion, now: now)
  }

  func testProgressMatchesRemainingRatioEachTick() {
    let now = makeDate()
    let model = makeModel(
      state: breakingState(now: now, remaining: 10, total: 30),
      settings: GKSettingsV1(breakSeconds: 30),
      now: now
    )
    XCTAssertTrue(model.isPresented)
    XCTAssertEqual(model.remainingSeconds, 10)
    XCTAssertEqual(model.totalSeconds, 30)
    XCTAssertEqual(model.progress, 10.0 / 30.0, accuracy: 1e-12)
  }

  func testRemainingRoundsUpToNextWholeSecond() {
    let now = makeDate()
    let model = makeModel(
      state: breakingState(now: now, remaining: 9.25, total: 30),
      settings: GKSettingsV1(breakSeconds: 30),
      now: now
    )
    XCTAssertEqual(model.remainingSeconds, 10)
    XCTAssertEqual(model.progress, 10.0 / 30.0, accuracy: 1e-12)
  }

  func testProgressClampsToOneWhenRemainingExceedsTotal() {
    let now = makeDate()
    let model = makeModel(
      state: breakingState(now: now, remaining: 45, total: 30),
      settings: GKSettingsV1(breakSeconds: 30),
      now: now
    )
    XCTAssertEqual(model.progress, 1.0, accuracy: 1e-12)
  }

  func testProgressFloorsAtZeroAfterNaturalEnd() {
    let now = makeDate()
    let model = makeModel(
      state: breakingState(now: now, remaining: -3, total: 30),
      settings: GKSettingsV1(breakSeconds: 30),
      now: now
    )
    XCTAssertEqual(model.remainingSeconds, 0)
    XCTAssertEqual(model.progress, 0.0, accuracy: 1e-12)
  }

  func testMessageComesFromFirstConfiguredMessage() {
    let now = makeDate()
    var settings = GKSettingsV1()
    settings.messages = ["Stretch your shoulders", "Unused second message"]
    let model = makeModel(
      state: breakingState(now: now, remaining: 12, total: 30),
      settings: settings,
      now: now
    )
    XCTAssertEqual(model.message, "Stretch your shoulders")
  }

  func testMessageRotatesAcrossBreaksAndWraps() {
    let now = makeDate()
    var settings = GKSettingsV1()
    settings.messages = ["One", "Two", "Three"]

    func modelFor(breaksStarted: Int) -> BreakOverlayModel {
      var state = breakingState(now: now, remaining: 12, total: 30)
      state.breaksStarted = breaksStarted
      return makeModel(state: state, settings: settings, now: now)
    }

    XCTAssertEqual(modelFor(breaksStarted: 1).message, "One")
    XCTAssertEqual(modelFor(breaksStarted: 2).message, "Two")
    XCTAssertEqual(modelFor(breaksStarted: 3).message, "Three")
    XCTAssertEqual(modelFor(breaksStarted: 4).message, "One")
  }

  func testMessageFallsBackToDefaultWhenListEmpty() {
    let now = makeDate()
    var settings = GKSettingsV1()
    settings.messages = []
    let model = makeModel(
      state: breakingState(now: now, remaining: 12, total: 30),
      settings: settings,
      now: now
    )
    XCTAssertEqual(model.message, GKSettingsV1.defaultMessages[0])
  }

  func testHiddenOutsideBreakingPhase() {
    let now = makeDate()
    var state = SchedulerState(
      phase: .idle,
      phaseStartedAt: now,
      nextDue: now.addingTimeInterval(600)
    )
    state.breakEndsAt = nil
    let model = makeModel(
      state: state,
      settings: GKSettingsV1(breakSeconds: 30),
      now: now
    )
    XCTAssertFalse(model.isPresented)
    XCTAssertEqual(model.remainingSeconds, 0)
    XCTAssertEqual(model.progress, 0.0, accuracy: 1e-12)
    XCTAssertEqual(model.totalSeconds, 30)
  }

  func testAllowEscMirrorsSetting() {
    let now = makeDate()
    var allowed = GKSettingsV1()
    allowed.allowEsc = true
    XCTAssertTrue(
      makeModel(
        state: breakingState(now: now, remaining: 5, total: 30),
        settings: allowed,
        now: now
      ).allowEsc)
    var denied = GKSettingsV1()
    denied.allowEsc = false
    XCTAssertFalse(
      makeModel(
        state: breakingState(now: now, remaining: 5, total: 30),
        settings: denied,
        now: now
      ).allowEsc)
  }

  func testReduceMotionPassesThroughToModel() {
    let now = makeDate()
    let model = makeModel(
      state: breakingState(now: now, remaining: 15, total: 30),
      settings: GKSettingsV1(breakSeconds: 30),
      reduceMotion: true,
      now: now
    )
    XCTAssertTrue(model.reduceMotion)
    XCTAssertEqual(model.remainingSeconds, 15)
    XCTAssertEqual(model.progress, 0.5, accuracy: 1e-12)
  }

  func testTotalFollowsConfiguredBreakSeconds() {
    let now = makeDate()
    let model = makeModel(
      state: breakingState(now: now, remaining: 20, total: 45),
      settings: GKSettingsV1(breakSeconds: 45),
      now: now
    )
    XCTAssertEqual(model.totalSeconds, 45)
    XCTAssertEqual(model.progress, 20.0 / 45.0, accuracy: 1e-12)
  }

  func testLiveLongBreakTotalUsesLongBreakSeconds() {
    let now = makeDate()
    var state = breakingState(now: now, remaining: 240, total: 300)
    state.currentBreakIsLong = true
    var settings = GKSettingsV1(breakSeconds: 20)
    settings.longBreakSeconds = 300
    let model = makeModel(state: state, settings: settings, now: now)
    XCTAssertTrue(model.isLong)
    XCTAssertEqual(model.totalSeconds, 300)
    XCTAssertEqual(model.progress, 240.0 / 300.0, accuracy: 1e-12)
  }

  func testLiveLongBreakMessageComesFromLongPool() {
    let now = makeDate()
    var state = breakingState(now: now, remaining: 240, total: 300)
    state.currentBreakIsLong = true
    state.breaksStarted = 1
    var settings = GKSettingsV1()
    settings.longBreakSeconds = 300
    settings.messages = ["short"]
    settings.longMessages = ["long one", "long two"]
    let model = makeModel(state: state, settings: settings, now: now)
    XCTAssertEqual(model.message, "long one")
  }

  func testPausedMidBreakShowsFrozenRemainder() {
    let now = makeDate()
    var state = breakingState(now: now, remaining: 13, total: 30)
    state.pausedByUser = true
    state.pausedRemaining = 9

    let laterProbe = now.addingTimeInterval(4)
    let model = makeModel(
      state: state,
      settings: GKSettingsV1(breakSeconds: 30),
      now: laterProbe
    )
    XCTAssertTrue(model.isPresented)
    XCTAssertEqual(model.remainingSeconds, 9)
    XCTAssertEqual(model.progress, 9.0 / 30.0, accuracy: 1e-12)

    let muchLater = now.addingTimeInterval(40)
    let stillFrozen = makeModel(
      state: state,
      settings: GKSettingsV1(breakSeconds: 30),
      now: muchLater
    )
    XCTAssertEqual(stillFrozen.remainingSeconds, 9)
  }
}
