import XCTest

@testable import GazeKeeperCore

final class CadenceAdvisorTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  /// `dues` evenly spaced dues across the window; `missed` of them get a
  /// follow-up event marking them skipped/postponed/worked-through.
  private func events(
    dues: Int, missed: Int, missedKind: BreakEventKind = .breakSkipped,
    reason: String? = "user"
  ) -> [LoggedEvent] {
    var out: [LoggedEvent] = []
    for i in 0..<dues {
      let at = now.addingTimeInterval(-TimeInterval(dues - i) * 3600)
      out.append(LoggedEvent(kind: .breakDue, at: at))
      if i < missed {
        out.append(
          LoggedEvent(kind: missedKind, reason: reason, at: at.addingTimeInterval(120)))
      }
    }
    return out
  }

  private func suggest(
    _ events: [LoggedEvent], interval: Int = 20, hasLongBreaks: Bool = false,
    dismissed: String? = nil
  ) -> CadenceSuggestion? {
    CadenceAdvisor.suggest(
      events: events, now: now,
      currentIntervalMinutes: interval, hasLongBreaks: hasLongBreaks,
      dismissedKey: dismissed)
  }

  func testTooFewDuesNeverSuggests() {
    XCTAssertNil(suggest(events(dues: 9, missed: 9)))
  }

  func testBoundaryFortyPercentIsNotAdvice() {
    // 4 / 10 == 0.4 exactly — not over the bar.
    XCTAssertNil(suggest(events(dues: 10, missed: 4)))
  }

  func testOverFortyPercentSuggestsNextMeaningfulStep() {
    let s = suggest(events(dues: 10, missed: 5))
    XCTAssertEqual(s?.kind, .longerInterval(minutes: 30))
    XCTAssertEqual(s?.dues, 10)
    XCTAssertEqual(s?.missedFraction ?? 0, 0.5, accuracy: 0.001)
  }

  func testWorkedThroughCountsAsMissedRest() {
    let s = suggest(events(dues: 10, missed: 5, missedKind: .breakWorked))
    XCTAssertEqual(s?.kind, .longerInterval(minutes: 30))
  }

  func testSystemPostponementsDoNotCount() {
    let s = suggest(
      events(dues: 10, missed: 6, missedKind: .breakPostponed, reason: "idle"))
    XCTAssertNil(s, "idle postponements are the machine's, not avoidance")
  }

  func testUserPostponementsCount() {
    let s = suggest(
      events(dues: 10, missed: 6, missedKind: .breakPostponed, reason: "user"))
    XCTAssertNotNil(s)
  }

  func testEventsOutsideTheWindowAreIgnored() {
    var old = events(dues: 10, missed: 8)
    for i in old.indices {
      old[i] = LoggedEvent(
        kind: old[i].kind, reason: old[i].reason,
        at: now.addingTimeInterval(-8 * 86_400 - TimeInterval(i)))
    }
    XCTAssertNil(suggest(old))
  }

  func testTopOfLadderSuggestsLongBreaks() {
    let s = suggest(events(dues: 10, missed: 5), interval: 60)
    XCTAssertEqual(s?.kind, .addLongBreaks)
  }

  func testTopOfLadderWithLongBreaksStaysQuiet() {
    XCTAssertNil(suggest(events(dues: 10, missed: 5), interval: 60, hasLongBreaks: true))
  }

  func testDismissedAdviceDoesNotReNag() {
    XCTAssertNil(suggest(events(dues: 10, missed: 5), dismissed: "interval:30"))
  }

  func testDismissedOtherAdviceStillAllowsNewAdvice() {
    // The dismissed key was for 45; current pattern suggests 30.
    let s = suggest(events(dues: 10, missed: 5), dismissed: "interval:45")
    XCTAssertEqual(s?.kind, .longerInterval(minutes: 30))
  }

  func testJustAppliedIntervalSuppressesStaleWindowAdvice() {
    // User applied 30 minutes ago; the window still holds the old
    // 20-min evidence — suggesting again immediately would be a re-nag.
    XCTAssertNil(
      suggest(events(dues: 10, missed: 5), interval: 30, dismissed: "applied:30"))
  }

  func testAppliedKeyDoesNotSuppressAfterIntervalChangesAgain() {
    let s = suggest(events(dues: 10, missed: 5), interval: 20, dismissed: "applied:30")
    XCTAssertEqual(s?.kind, .longerInterval(minutes: 30))
  }
}
