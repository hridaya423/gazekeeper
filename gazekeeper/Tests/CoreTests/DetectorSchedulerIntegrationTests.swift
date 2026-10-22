import XCTest

@testable import GazeKeeperCore

final class DetectorSchedulerIntegrationTests: XCTestCase {

  private let epoch = Date(timeIntervalSince1970: 1_775_000_000)

  private func makeScheduler() -> Scheduler {
    let settings = GKSettingsV1()
    let idle = FixedIdleProvider(idleSeconds: 0)
    return Scheduler(settings: settings, now: epoch, idleProvider: idle)
  }

  private let cameraOn = DetectorSignals(cameraRunning: true)
  private let cameraOff = DetectorSignals()

  func testCameraPauseFreezesCountdownAndSuppressesHeadsUp() {
    let scheduler = makeScheduler()
    let engine = DetectorEngine(settings: GKSettingsV1())
    let decision = engine.process(signals: cameraOn, at: epoch)
    XCTAssertEqual(decision?.reason, .camera)

    apply(decision, to: scheduler, at: epoch)
    XCTAssertTrue(scheduler.currentState().pausedByDetector)
    XCTAssertEqual(scheduler.currentState().effectiveRemaining(from: epoch), 1200)

    _ = scheduler.tick(epoch.addingTimeInterval(30 * 60))
    XCTAssertEqual(
      scheduler.currentState().phase, .idle,
      "no heads-up may start while a detector keeps the scheduler paused")

    let resumeAt = epoch.addingTimeInterval(31 * 60)
    let resumed = engine.process(signals: cameraOff, at: resumeAt)
    XCTAssertEqual(resumed?.action, .resumed)
    apply(resumed, to: scheduler, at: resumeAt)
    XCTAssertFalse(scheduler.currentState().pausedByDetector)
    XCTAssertEqual(
      scheduler.currentState().effectiveRemaining(from: resumeAt), 1200,
      "countdown resumes from where the pause froze it")
  }

  func testDetectorPauseBlocksManualBreakTrigger() {
    let scheduler = makeScheduler()
    scheduler.setPaused(byUser: false, byDetector: true, at: epoch)
    XCTAssertTrue(scheduler.triggerBreak(at: epoch).isEmpty)
    XCTAssertFalse(scheduler.currentState().phase == .breaking)

    scheduler.setPaused(byUser: false, byDetector: false, at: epoch)
    XCTAssertFalse(scheduler.triggerBreak(at: epoch).isEmpty)
    XCTAssertEqual(scheduler.currentState().phase, .breaking)
  }

  func testDetectorPauseDuringBreakingInterruptsBreak() {
    let scheduler = makeScheduler()
    _ = scheduler.triggerBreak(at: epoch)
    XCTAssertEqual(scheduler.currentState().phase, .breaking)

    let pauseAt = epoch.addingTimeInterval(5)
    let events = scheduler.setPaused(byUser: false, byDetector: true, at: pauseAt)
    XCTAssertEqual(events.map(\.kind), [.breakInterrupted])
    XCTAssertEqual(events.first?.reason, "detector")
    let frozen = scheduler.currentState()
    XCTAssertEqual(frozen.phase, .cooldown)
    XCTAssertNil(frozen.breakEndsAt)

    let stillPausedAt = epoch.addingTimeInterval(600)
    _ = scheduler.tick(stillPausedAt)
    XCTAssertEqual(
      scheduler.currentState().phase, .cooldown,
      "the interrupted break stays ended; the pause holds the cooldown")

    let resumeAt = epoch.addingTimeInterval(700)
    scheduler.setPaused(byUser: false, byDetector: false, at: resumeAt)
    _ = scheduler.tick(resumeAt + 30)
    XCTAssertEqual(scheduler.currentState().phase, .idle)
  }

  func testUserPauseAndResumeOutlivesDetectorPause() {
    let scheduler = makeScheduler()
    scheduler.setPaused(byUser: true, byDetector: nil, at: epoch)
    scheduler.setPaused(byUser: nil, byDetector: true, at: epoch.addingTimeInterval(10))
    XCTAssertTrue(scheduler.currentState().isPaused())

    scheduler.setPaused(byUser: nil, byDetector: false, at: epoch.addingTimeInterval(20))
    XCTAssertTrue(
      scheduler.currentState().pausedByUser,
      "detector resume must not lift an independent user pause")
    XCTAssertTrue(scheduler.currentState().isPaused())

    scheduler.setPaused(byUser: false, byDetector: nil, at: epoch.addingTimeInterval(30))
    XCTAssertFalse(scheduler.currentState().isPaused())
  }

  func testEngineDecisionEventsFeedSchedulerPause() {
    let scheduler = makeScheduler()
    let engine = DetectorEngine(settings: GKSettingsV1())
    let fullscreen = DetectorSignals(fullscreenActive: true)

    let paused = engine.process(signals: fullscreen, at: epoch)
    XCTAssertEqual(paused?.detectorID, "fullscreen")
    apply(paused, to: scheduler, at: epoch)
    XCTAssertTrue(scheduler.currentState().pausedByDetector)

    let resumed = engine.process(signals: DetectorSignals(), at: epoch.addingTimeInterval(10))
    XCTAssertEqual(resumed?.detectorID, "fullscreen")
    XCTAssertEqual(resumed?.action, .resumed)
    apply(resumed, to: scheduler, at: epoch.addingTimeInterval(10))
    XCTAssertFalse(scheduler.currentState().pausedByDetector)
  }

  private func apply(
    _ decision: DetectorDecision?, to scheduler: Scheduler, at now: Date
  ) {
    guard let decision else { return }
    switch decision.action {
    case .paused:
      scheduler.setPaused(byUser: nil, byDetector: true, at: now)
    case .resumed:
      scheduler.setPaused(byUser: nil, byDetector: false, at: now)
    }
  }
}
