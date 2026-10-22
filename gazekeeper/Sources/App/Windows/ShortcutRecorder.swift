import AppKit
import Carbon.HIToolbox
import GazeKeeperCore
import SwiftUI

/// A settings row that records a global shortcut: click to capture the
/// next key-down (Esc cancels, Delete clears), then writes the binding
/// into settings so the HotKeyCenter re-registers immediately.
struct ShortcutRecorderRow: View {
  @Environment(\.gkAccent) private var accent: Color
  let title: String
  let action: ShortcutAction
  let controller: AppStateController
  let failed: Bool

  @State private var isRecording = false
  @State private var monitor: Any?

  var body: some View {
    HStack {
      Text(title)
        .font(Tokens.Typography.body)
        .foregroundStyle(Tokens.Color.text)
      Spacer()
      if failed {
        Text("Couldn't register — shortcut already taken")
          .font(Tokens.Typography.caption)
          .foregroundStyle(Tokens.Color.warm)
      }
      Button(action: toggleRecording) {
        Text(buttonTitle)
          .font(Tokens.Typography.countdown)
          .foregroundStyle(Tokens.Color.text)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .frame(minWidth: 88)
          .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(
                isRecording
                  ? accent.opacity(0.2)
                  : Tokens.Color.rowHover
              )
              .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .strokeBorder(
                    isRecording
                      ? accent
                      : accent.opacity(0.35),
                    lineWidth: 1)
              )
          )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(title) shortcut")
      .accessibilityHint(
        isRecording
          ? "Press a key combination, Escape to cancel, Delete to clear"
          : "Record a new shortcut")
    }
    .onDisappear { stopRecording() }
  }

  private var buttonTitle: String {
    if isRecording { return "Press shortcut…" }
    guard let descriptor = controller.currentSettings.shortcuts[action] else {
      return "Record"
    }
    return ShortcutFormatter.string(for: descriptor)
  }

  private func toggleRecording() {
    if isRecording {
      stopRecording()
    } else {
      isRecording = true
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        MainActor.assumeIsolated {
          capture(event)
        }
        return nil
      }
    }
  }

  private func capture(_ event: NSEvent) {
    // Esc cancels; bare Delete/Backspace clears the binding.
    if event.keyCode == UInt16(kVK_Escape) {
      stopRecording()
      return
    }
    if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
      write(nil)
      return
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let carbon = ShortcutFormatter.carbonModifiers(for: modifiers)
    // A global hotkey without a modifier would eat ordinary typing.
    guard carbon != 0 else { return }
    write(
      ShortcutDescriptor(
        keyCode: UInt32(event.keyCode), carbonModifiers: carbon))
  }

  private func write(_ descriptor: ShortcutDescriptor?) {
    let action = self.action
    controller.updateSettings { $0.shortcuts[action] = descriptor }
    stopRecording()
  }

  private func stopRecording() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    isRecording = false
  }
}

enum ShortcutFormatter {

  /// NSEvent modifier flags → the Carbon hotkey mask Carbon expects.
  static func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
    var mask: UInt32 = 0
    if flags.contains(.control) { mask |= UInt32(controlKey) }
    if flags.contains(.option) { mask |= UInt32(optionKey) }
    if flags.contains(.shift) { mask |= UInt32(shiftKey) }
    if flags.contains(.command) { mask |= UInt32(cmdKey) }
    return mask
  }

  static func string(for descriptor: ShortcutDescriptor) -> String {
    var glyphs = ""
    let mods = descriptor.carbonModifiers
    if mods & UInt32(controlKey) != 0 { glyphs += "⌃" }
    if mods & UInt32(optionKey) != 0 { glyphs += "⌥" }
    if mods & UInt32(shiftKey) != 0 { glyphs += "⇧" }
    if mods & UInt32(cmdKey) != 0 { glyphs += "⌘" }
    return glyphs + keyName(for: descriptor.keyCode)
  }

  private static func keyName(for keyCode: UInt32) -> String {
    if let special = specialKeyNames[keyCode] { return special }
    guard
      let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
        .takeRetainedValue(),
      let data = TISGetInputSourceProperty(
        source, kTISPropertyUnicodeKeyLayoutData)
    else { return "?" }
    let layout = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
    let keys = unsafeBitCast(
      CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self)
    var deadKeys: UInt32 = 0
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    let status = UCKeyTranslate(
      keys, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
      UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
      &deadKeys, chars.count, &length, &chars)
    guard status == noErr, length > 0 else { return "?" }
    return String(utf16CodeUnits: chars, count: length).uppercased()
  }

  private static let specialKeyNames: [UInt32: String] = [
    UInt32(kVK_Space): "Space",
    UInt32(kVK_Return): "↩",
    UInt32(kVK_Tab): "⇥",
    UInt32(kVK_Delete): "⌫",
    UInt32(kVK_ForwardDelete): "⌦",
    UInt32(kVK_Escape): "⎋",
    UInt32(kVK_LeftArrow): "←",
    UInt32(kVK_RightArrow): "→",
    UInt32(kVK_UpArrow): "↑",
    UInt32(kVK_DownArrow): "↓",
    UInt32(kVK_Home): "↖",
    UInt32(kVK_End): "↘",
    UInt32(kVK_PageUp): "⇞",
    UInt32(kVK_PageDown): "⇟",
    UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
    UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
    UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
    UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
  ]
}
