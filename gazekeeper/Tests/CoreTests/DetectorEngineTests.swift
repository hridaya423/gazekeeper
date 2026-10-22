import XCTest

@testable import GazeKeeperCore

final class DetectorEngineTests: XCTestCase {

  private let epoch = Date(timeIntervalSince1970: 1_775_000_000)

  private func makeEngine(
    configure: (inout GKSettingsV1) -> Void = { _ in }
  ) -> DetectorEngine {
    var settings = GKSettingsV1()
    configure(&settings)
    return DetectorEngine(settings: settings)
  }

  private func signals(
    camera: Bool = false, mic: Bool = false, sharing: Bool = false,
    fullscreen: Bool = false, frontmost: String? = nil
  ) -> DetectorSignals {
    DetectorSignals(
      cameraRunning: camera, microphoneRunning: mic, screenSharing: sharing,
      fullscreenActive: fullscreen, frontmostBundleId: frontmost)
  }

  // MARK: - individual signals

  func testCameraAlonePausesWithCameraReason() {
    let engine = makeEngine()
    let decision = engine.process(signals: signals(camera: true), at: epoch)
    XCTAssertEqual(decision?.action, .paused)
    XCTAssertEqual(decision?.reason, .camera)
    XCTAssertEqual(engine.currentReason, .camera)
  }

  func testMicrophoneAlonePauses() {
    let engine = makeEngine()
    let decision = engine.process(signals: signals(mic: true), at: epoch)
    XCTAssertEqual(decision?.reason, .microphone)
  }

  func testScreenSharingAlonePauses() {
    let engine = makeEngine()
    let decision = engine.process(signals: signals(sharing: true), at: epoch)
    XCTAssertEqual(decision?.reason, .screenSharing)
  }

  func testFullscreenAlonePauses() {
    let engine = makeEngine()
    let decision = engine.process(signals: signals(fullscreen: true), at: epoch)
    XCTAssertEqual(decision?.reason, .fullscreen)
  }

  func testNoSignalsSteadyStateEmitsNothing() {
    let engine = makeEngine()
    XCTAssertNil(engine.process(signals: signals(), at: epoch))
    XCTAssertNil(engine.process(signals: signals(), at: epoch))
  }

  // MARK: - edges and reasons

  func testResumeCarriesThePauseReason() {
    let engine = makeEngine()
    _ = engine.process(signals: signals(camera: true), at: epoch)
    let resume = engine.process(signals: signals(), at: epoch.addingTimeInterval(60))
    XCTAssertEqual(resume?.action, .resumed)
    XCTAssertEqual(resume?.reason, .camera)
    XCTAssertNil(engine.currentReason)
  }

  func testSwappingSignalsStaysPausedAndTracksLiveReason() {
    let engine = makeEngine()
    _ = engine.process(signals: signals(camera: true), at: epoch)
    // Camera off, mic on: still paused, explanation follows the live
    // signal, and no new decision fires on the swap.
    let swap = engine.process(signals: signals(mic: true), at: epoch.addingTimeInterval(5))
    XCTAssertNil(swap)
    XCTAssertEqual(engine.currentReason, .microphone)
    let resume = engine.process(signals: signals(), at: epoch.addingTimeInterval(10))
    XCTAssertEqual(resume?.reason, .microphone)
  }

  func testAppRuleBeatsHardwareSignals() {
    let engine = makeEngine { settings in
      settings.appRules["com.cisco.webexmeetings"] = .pause
    }
    let decision = engine.process(
      signals: signals(camera: true, frontmost: "com.cisco.webexmeetings"), at: epoch)
    XCTAssertEqual(decision?.reason, .appRule("com.cisco.webexmeetings"))
  }

  func testHardwareBeatsFullscreen() {
    let engine = makeEngine()
    let decision = engine.process(
      signals: signals(camera: true, fullscreen: true), at: epoch)
    XCTAssertEqual(decision?.reason, .camera)
  }

  // MARK: - switches and rules

  func testDisabledSignalDoesNotPause() {
    let engine = makeEngine { settings in
      settings.detectors["camera"] = DetectorSettings(enabled: false)
    }
    XCTAssertNil(engine.process(signals: signals(camera: true), at: epoch))
  }

  func testIgnoreRuleSuppressesFullscreenButNotHardware() {
    let engine = makeEngine { settings in
      settings.appRules["com.vlc"] = .ignore
    }
    XCTAssertNil(
      engine.process(
        signals: signals(fullscreen: true, frontmost: "com.vlc"), at: epoch))
    // A camera still pauses — the device isn't the app's own business.
    let decision = engine.process(
      signals: signals(camera: true, frontmost: "com.vlc"), at: epoch)
    XCTAssertEqual(decision?.reason, .camera)
  }

  func testSlackIdleWithoutCallSignalsNeverPauses() {
    let engine = makeEngine()
    XCTAssertNil(
      engine.process(
        signals: signals(frontmost: "com.tinyspeck.slackmacgap"), at: epoch))
  }

  func testEventReasonRoundTripsForLog() {
    XCTAssertEqual(DetectorReason.camera.eventReason, "camera")
    XCTAssertEqual(DetectorReason.screenSharing.eventReason, "screen_sharing")
    XCTAssertEqual(DetectorReason.appRule("com.x").eventReason, "app_rule:com.x")
  }
}
