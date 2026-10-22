import AppKit
import SwiftUI

/// The entire visual vocabulary. Semantic system colors for text and
/// surfaces — they adapt to light/dark for free — plus one calm
/// teal-green accent, defined in exactly one place. No Color(hex:)
/// may exist outside this file.
enum Tokens {

  enum Color {
    static let text = SwiftUI.Color(nsColor: .labelColor)
    static let textSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
    static let textTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
    static let separator = SwiftUI.Color(nsColor: .separatorColor)
    /// Card fill over the window background.
    static let card = SwiftUI.Color(nsColor: .controlBackgroundColor)
    /// Quiet warning tone (detector pause, snooze budget empty).
    static let warm = SwiftUI.Color(nsColor: .systemOrange)

    /// One accent, one place: the site's chart-line teal, lifted in dark
    /// mode for contrast against dimmed surfaces.
    static let accent = SwiftUI.Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(hex: 0x5fc4b8)
          : NSColor(hex: 0x0e7c72)
      })

    /// On-accent text for filled controls — white over the deep light-mode
    /// teal, dark over the lifted dark-mode teal (WCAG-safe either way).
    static let onAccent = SwiftUI.Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(hex: 0x053731)
          : NSColor.white
      })

    /// Window chrome behind content.
    static let windowBackground = SwiftUI.Color(nsColor: .windowBackgroundColor)
    /// The break overlay's dimming layer.
    static let scrim = SwiftUI.Color.black.opacity(0.55)
    /// The solid break background — a calm near-black, calm in both modes
    /// because the overlay is its own world, not a window.
    static let overlaySolid = SwiftUI.Color(
      nsColor: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1))
    /// Hover fill for popover/menu rows.
    static let rowHover = SwiftUI.Color(nsColor: .labelColor).opacity(0.06)
    /// Hairline separators inside surfaces.
    static let hairline = SwiftUI.Color(nsColor: .separatorColor)

    /// Text on the break overlay's dark scrim — always light, both modes.
    static let onScrim = SwiftUI.Color.white
    static let onScrimSecondary = SwiftUI.Color.white.opacity(0.62)
    /// Fills for controls floating on the scrim.
    static let onScrimFill = SwiftUI.Color.white.opacity(0.10)
    static let onScrimStroke = SwiftUI.Color.white.opacity(0.16)
  }

  enum Typography {
    /// Optician Sans — the eye-chart face, bundled under the OFL. Digits
    /// and capitals only read as intended; never set body copy in it.
    static func chart(_ size: CGFloat) -> Font {
      .custom("OpticianSans-Regular", fixedSize: size)
    }
    static let title = Font.system(size: 20, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    /// The break timer's digits — large, tabular, calm.
    static let overlayTimer = Font.system(size: 88, weight: .light, design: .rounded)
      .monospacedDigit()
    static let countdown = Font.system(size: 13, weight: .medium, design: .rounded)
      .monospacedDigit()
    /// ALL-CAPS eyebrow labels over the scrim ("EYE BREAK", "LONG BREAK").
    static let eyebrow = Font.system(size: 13, weight: .semibold, design: .rounded)
    /// The one-line break message under the ring.
    static let overlayMessage = Font.system(size: 30, weight: .medium)
    /// Primary capsule buttons on floating surfaces ("Skip break").
    static let controlTitle = Font.system(size: 15, weight: .semibold)
    /// Kbd-style hint ("esc").
    static let keyCap = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let callout = Font.system(size: 12)
    /// Small capsule buttons inside pills ("Start now", "Snooze 5m").
    static let chipLabel = Font.system(size: 12, weight: .semibold)
    /// The pill's live countdown — accent digit over a capsule.
    static let pillCountdown = Font.system(size: 14, weight: .semibold, design: .rounded)
      .monospacedDigit()
  }

  /// SF Symbol glyph sizes applied via `.font(_:)` — one value per usage
  /// site so symbol weight stays consistent with the type ramp.
  enum Icon {
    static let row = Font.system(size: 12, weight: .medium)
    static let toast = Font.system(size: 15, weight: .semibold)
    static let small = Font.system(size: 11, weight: .semibold)
  }

  enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
  }

  enum Radius {
    static let card: CGFloat = 12
    static let control: CGFloat = 8
    static let pill: CGFloat = 14
  }

  enum Motion {
    /// Standard UI ease — the only curve the app needs.
    static let ui = Animation.easeOut(duration: 0.2)
    static let gentle = Animation.easeInOut(duration: 0.35)
  }
}

extension NSColor {
  convenience init(hex: UInt32, alpha: Double = 1) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: CGFloat(alpha))
  }
}
