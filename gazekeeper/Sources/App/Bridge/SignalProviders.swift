import AppKit
import CoreAudio
import CoreMediaIO
import GazeKeeperCore

/// Hardware-backed detector signals. Every provider is event-driven —
/// property listeners push state changes; nothing polls.

/// A CoreAudio input device is running while an app holds the mic.
/// Listens on the default input and re-attaches when the default
/// device changes (headset plugged in, Continuity Camera mic, …).
final class MicrophoneSignalProvider: @unchecked Sendable {

  private let queue = DispatchQueue(label: "com.hridya.gazekeeper.mic-signal")
  private let lock = NSLock()
  private var listenedDevice: AudioDeviceID = 0
  private var running = false

  /// Fires on MainActor whenever the running state may have changed.
  var onChange: (() -> Void)?

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  func start() {
    queue.async { [weak self] in
      self?.attachToDefaultDevice()
      self?.listenForDefaultDeviceChanges()
    }
  }

  /// One stable block instance — listener removal must pass the
  /// identical block that was added.
  private lazy var micListenerBlock: AudioObjectPropertyListenerBlock = {
    [weak self] _, _ in
    guard let self else { return }
    self.queue.async { self.refreshRunning() }
  }

  private static var runningAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: AudioObjectPropertySelector(kAudioDevicePropertyDeviceIsRunning),
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  private func attachToDefaultDevice() {
    var addr = Self.runningAddress
    if listenedDevice != 0 {
      AudioObjectRemovePropertyListenerBlock(
        listenedDevice, &addr, queue, micListenerBlock)
      listenedDevice = 0
    }
    let device = Self.defaultInputDevice()
    guard device != 0 else {
      running = false
      return
    }
    listenedDevice = device
    AudioObjectAddPropertyListenerBlock(
      device, &addr, queue, micListenerBlock)
    refreshRunning()
  }

  private func refreshRunning() {
    guard listenedDevice != 0 else { return }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = Self.runningAddress
    AudioObjectGetPropertyData(listenedDevice, &addr, 0, nil, &size, &value)
    let nowRunning = value != 0
    if nowRunning != isRunning {
      running = nowRunning
      notify()
    }
  }

  private func listenForDefaultDeviceChanges() {
    var addr = AudioObjectPropertyAddress(
      mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultInputDevice),
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &addr, queue
    ) { [weak self] _, _ in
      guard let self else { return }
      self.queue.async { self.attachToDefaultDevice() }
    }
  }

  private static func defaultInputDevice() -> AudioDeviceID {
    var device: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultInputDevice),
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
    return device
  }

  private func notify() {
    let change = onChange
    DispatchQueue.main.async { change?() }
  }
}

/// A CoreMediaIO camera is running while any app captures from it —
/// the most honest "in a call" signal the OS offers. Re-enumerates
/// devices when the hardware set changes (Continuity Camera, unplug).
final class CameraSignalProvider: @unchecked Sendable {

  private let queue = DispatchQueue(label: "com.hridya.gazekeeper.camera-signal")
  private let lock = NSLock()
  private var watchedDevices = Set<CMIODeviceID>()
  private var running = false

  var onChange: (() -> Void)?

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  func start() {
    queue.async { [weak self] in
      self?.watchDevices()
      self?.listenForDeviceSetChanges()
    }
  }

  private lazy var deviceListenerBlock: CMIOObjectPropertyListenerBlock = {
    [weak self] _, _ in
    guard let self else { return }
    self.queue.async { self.refreshRunning() }
  }

  private static var runningAddress: CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunning),
      mScope: kCMIOObjectPropertyScopeWildcard,
      mElement: kCMIOObjectPropertyElementWildcard)
  }

  private func watchDevices() {
    var addr = Self.runningAddress
    for device in watchedDevices {
      CMIOObjectRemovePropertyListenerBlock(
        device, &addr, queue, deviceListenerBlock)
    }
    watchedDevices = Set(Self.cameraDevices())
    for device in watchedDevices {
      CMIOObjectAddPropertyListenerBlock(
        device, &addr, queue, deviceListenerBlock)
    }
    refreshRunning()
  }

  private func refreshRunning() {
    var addr = Self.runningAddress
    var anyRunning = false
    for device in watchedDevices {
      var value: UInt32 = 0
      let size = UInt32(MemoryLayout<UInt32>.size)
      var used: UInt32 = 0
      if CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &value)
        == noErr, value != 0
      {
        anyRunning = true
        break
      }
    }
    if anyRunning != isRunning {
      running = anyRunning
      notify()
    }
  }

  private func listenForDeviceSetChanges() {
    var addr = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    CMIOObjectAddPropertyListenerBlock(
      CMIOObjectID(kCMIOObjectSystemObject), &addr, queue
    ) { [weak self] _, _ in
      guard let self else { return }
      self.queue.async { self.watchDevices() }
    }
  }

  private static func cameraDevices() -> [CMIODeviceID] {
    var addr = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    guard
      CMIOObjectGetPropertyDataSize(
        CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size)
        == noErr, size > 0
    else { return [] }
    let count = Int(size) / MemoryLayout<CMIODeviceID>.size
    var devices = [CMIODeviceID](repeating: 0, count: count)
    guard
      CMIOObjectGetPropertyData(
        CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &size,
        &devices)
        == noErr
    else { return [] }
    return devices
  }

  private func notify() {
    let change = onChange
    DispatchQueue.main.async { change?() }
  }
}

/// System screen sharing/recording is visible as windows owned by the
/// sharing daemons — observable without screen-capture permission.
final class ScreenShareProvider {

  private static let sharingOwnerNames: Set<String> = [
    "screensharingd", "sharingd", "replayd", "screencontinuityd",
    "ScreensharingAgent", "SSMenuAgent",
  ]

  func isSharing() -> Bool {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return false }
    return raw.contains { window in
      guard let owner = window[kCGWindowOwnerName as String] as? String
      else { return false }
      return Self.sharingOwnerNames.contains(owner.lowercased())
    }
  }
}
