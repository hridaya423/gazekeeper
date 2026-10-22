import AppKit
import Foundation
import GazeKeeperCore

@MainActor
final class SingleInstanceCoordinator: NSObject {
  static let revealNotificationName = Notification.Name("com.hridya.gazekeeper.menu-reveal")

  private weak var appDelegate: AppDelegate?
  private let lockHandle: FileHandle?
  private(set) var ownsLock = false

  init(appDelegate: AppDelegate, lockURL: URL) {
    self.appDelegate = appDelegate
    // The lock lives inside the data directory, which may not exist on a
    // fresh install — create it or the first launch would fail to take the
    // lock and exit as if a primary instance were already running.
    try? FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: lockURL.path, contents: nil)
    let handle = FileHandle(forWritingAtPath: lockURL.path)
    self.lockHandle = handle
    if let handle, flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
      self.ownsLock = true
    }
    super.init()
  }

  /// Claims the primary instance. When another instance already holds the
  /// lock, asks it to reveal its menu and returns false so the caller can
  /// exit immediately without booting (no sessions, no stats writes).
  func claimPrimaryInstance() -> Bool {
    if ownsLock {
      DistributedNotificationCenter.default().addObserver(
        self, selector: #selector(handleRevealNotification),
        name: Self.revealNotificationName, object: nil)
      NSLog("GazeKeeper single-instance lock acquired as first instance")
      return true
    }
    DistributedNotificationCenter.default().postNotificationName(
      Self.revealNotificationName, object: nil,
      userInfo: ["pid": String(ProcessInfo.processInfo.processIdentifier)],
      deliverImmediately: true)
    NSLog("GazeKeeper second instance signaled the running instance")
    return false
  }

  @objc private func handleRevealNotification(_ notification: Notification) {
    NSLog("GazeKeeper menu reveal requested by second launch")
    appDelegate?.controller?.appendMenuRevealedEvent(reason: "second_launch")
    appDelegate?.activateForMenuReveal()
  }
}

#if DEBUG
  enum SingleInstanceCoordinatorRevealBridge {
    @MainActor
    static func revealForDebug() {
      NSLog("GazeKeeper menu reveal requested via debug command")
      AppDelegate.shared?.controller?.appendMenuRevealedEvent(reason: "second_launch")
      AppDelegate.shared?.activateForMenuReveal()
    }
  }
#endif
