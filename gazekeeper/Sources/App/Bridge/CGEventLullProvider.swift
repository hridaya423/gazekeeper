import CoreGraphics
import Foundation
import GazeKeeperCore

/// `CGEventSource.secondsSinceLastEventType` — no Accessibility needed for
/// the "when did anything last happen" question (unlike an event tap).
struct CGEventLullProvider: GKInputLullProviding {
  private let state = CGEventSourceStateID.combinedSessionState
  private let watched: [CGEventType] = [
    .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel,
  ]

  func secondsSinceLastInput() -> TimeInterval {
    watched
      .map { CGEventSource.secondsSinceLastEventType(state, eventType: $0) }
      .min() ?? .infinity
  }
}
