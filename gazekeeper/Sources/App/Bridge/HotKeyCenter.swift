import AppKit
import Carbon.HIToolbox
import Foundation
import GazeKeeperCore

/// Global hotkeys via Carbon RegisterEventHotKey: real capture (the
/// keystroke never reaches the foreground app), no accessibility
/// permission needed, and a real failure signal when a combination is
/// already claimed — which the Settings surface reports honestly.
@MainActor
final class HotKeyCenter {
  static let shared = HotKeyCenter()

  static let signature = OSType(fourCC: "gzkp")

  private var registered: [UInt32: (ref: EventHotKeyRef?, action: ShortcutAction)] = [:]
  private var dispatch: ((ShortcutAction) -> Void)?

  /// Bindings that failed registration (e.g. claimed by another app).
  /// Settings renders this so a dead hotkey is never silently absent.
  private(set) var failedActions: Set<ShortcutAction> = []

  /// Re-registers every bound action. Safe to call on every settings
  /// change — existing hotkeys are torn down first.
  func sync(bindings: ShortcutBindings, dispatch: @escaping (ShortcutAction) -> Void) {
    self.dispatch = dispatch
    for entry in registered.values {
      if let ref = entry.ref { UnregisterEventHotKey(ref) }
    }
    registered.removeAll()
    failedActions.removeAll()
    guard installCarbonEventHandler() else {
      failedActions = Set(bindings.boundActions.map { $0.action })
      return
    }
    var seen = Set<ShortcutDescriptor>()
    var nextID: UInt32 = 1
    for binding in bindings.boundActions {
      // The same combo on two actions can't both register — the second
      // is surfaced as a failure rather than silently shadowed.
      guard seen.insert(binding.descriptor).inserted else {
        failedActions.insert(binding.action)
        continue
      }
      let hotKeyID = EventHotKeyID(signature: Self.signature, id: nextID)
      nextID += 1
      var ref: EventHotKeyRef?
      let status = RegisterEventHotKey(
        binding.descriptor.keyCode, binding.descriptor.carbonModifiers,
        hotKeyID, GetApplicationEventTarget(), 0, &ref)
      if status == noErr {
        registered[hotKeyID.id] = (ref, binding.action)
      } else {
        failedActions.insert(binding.action)
      }
    }
  }

  /// Invoked by the Carbon handler for any registered hotkey id, and by
  /// the debug server's simulateHotKey command.
  func handleHotKey(id: UInt32) {
    guard let action = registered[id]?.action else { return }
    dispatch?(action)
  }

  /// Test/debug path: fire an action without a registered hotkey.
  func simulate(_ action: ShortcutAction) {
    dispatch?(action)
  }

  nonisolated(unsafe) private static var eventHandlerInstalled = false

  private func installCarbonEventHandler() -> Bool {
    guard !Self.eventHandlerInstalled else { return true }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: EventParamName(kEventHotKeyPressed))
    let selfBox = HotKeyBox(center: self)
    let userDataRef = Unmanaged.passRetained(selfBox).toOpaque()
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { event, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject),
          // typeEventHotKeyID, not exposed in Swift's Carbon overlay
          EventParamType(OSType(fourCC: "hkid")), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        let box = Unmanaged<HotKeyBox>.fromOpaque(userData).takeUnretainedValue()
        let id = hotKeyID.id
        Task { @MainActor in
          box.center.handleHotKey(id: id)
        }
        return noErr
      },
      1, &eventType, userDataRef, nil)
    if status == noErr {
      Self.eventHandlerInstalled = true
      hotKeyBox = selfBox
    } else {
      Unmanaged<HotKeyBox>.fromOpaque(userDataRef).release()
    }
    return status == noErr
  }

  private final class HotKeyBox {
    let center: HotKeyCenter

    init(center: HotKeyCenter) {
      self.center = center
    }
  }

  nonisolated(unsafe) private var hotKeyBox: HotKeyBox?
}

extension OSType {
  init(fourCC: String) {
    var value: UInt32 = 0
    for byte in fourCC.utf8 {
      value = (value << 8) + UInt32(byte)
    }
    self = value
  }
}
