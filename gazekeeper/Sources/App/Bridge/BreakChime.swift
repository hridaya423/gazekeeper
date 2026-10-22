import AppKit

/// The soft chime played when a break ends, honoring `soundEnabled`.
enum BreakChime {
  static func play() {
    NSSound(named: NSSound.Name("Glass"))?.play()
  }
}
