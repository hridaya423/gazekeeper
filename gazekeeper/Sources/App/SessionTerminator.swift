import AppKit
import GazeKeeperCore

final class AppTerminator: SessionTerminating {
  init() {}

  func terminate() {
    NSApp.terminate(nil)
  }
}
