import AppKit
import CoreGraphics
import Foundation
import GazeKeeperCore

struct CGIdleProvider: GKIdleProviding {

  let source: CGEventSourceStateID

  init(source: CGEventSourceStateID = .combinedSessionState) {
    self.source = source
  }

  func currentIdleSeconds() -> TimeInterval {
    Double(CGEventSource.secondsSinceLastEventType(source, eventType: CGEventType.anyInput))
  }
}

extension CGEventType {
  static let anyInput = CGEventType(rawValue: UInt32.max)!
}
