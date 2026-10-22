import Foundation

/// Advice the dashboard can offer: a longer cadence, or long breaks when
/// the interval is already maxed. `dismissKey` is the suggestion's stable
/// identity — re-offering the same advice is suppressed, a shifted
/// pattern is new advice.
public struct CadenceSuggestion: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case longerInterval(minutes: Int)
    case addLongBreaks
  }

  public let kind: Kind
  /// The evidence line: dues observed in the window and the fraction of
  /// them that got no rest.
  public let dues: Int
  public let missedFraction: Double

  public var dismissKey: String {
    switch kind {
    case .longerInterval(let minutes): return "interval:\(minutes)"
    case .addLongBreaks: return "longbreaks"
    }
  }

  public init(kind: Kind, dues: Int, missedFraction: Double) {
    self.kind = kind
    self.dues = dues
    self.missedFraction = missedFraction
  }
}

/// Reads the event log for cadence fatigue: when the user lets more than
/// 40% of dues slip over a week, the current interval is probably too
/// aggressive. Pure function — the app layer wires the card's Apply and
/// Dismiss back into settings.
public enum CadenceAdvisor {
  /// Rungs of the suggestion ladder. A suggestion is the smallest rung at
  /// least 1.5× the current interval — enough change to matter.
  public static let ladder = [10, 15, 20, 25, 30, 45, 60]
  public static let minimumDues = 10
  public static let missedThreshold = 0.4

  /// `dismissedKey` is `settings.dismissedCadenceSuggestion`. Besides the
  /// exact-advice match, `applied:<interval>` suppresses everything: the
  /// window is stale evidence measured under the old cadence.
  public static func suggest(
    events: [LoggedEvent], now: Date, calendar: Calendar = .current,
    currentIntervalMinutes: Int, hasLongBreaks: Bool,
    dismissedKey: String? = nil, windowDays: Int = 7
  ) -> CadenceSuggestion? {
    if dismissedKey == "applied:\(currentIntervalMinutes)" { return nil }
    let windowStart = now.addingTimeInterval(-TimeInterval(windowDays) * 86_400)
    var dues = 0
    var missed = 0
    for event in events where event.at > windowStart && event.at <= now {
      switch event.kind {
      case .breakDue:
        dues += 1
      case .breakSkipped, .breakWorked:
        missed += 1
      case .breakPostponed:
        // System postponements are not the user dodging rest.
        if event.reason != "idle" && event.reason != "office_hours" {
          missed += 1
        }
      default:
        break
      }
    }
    guard dues >= minimumDues else { return nil }
    let fraction = Double(missed) / Double(dues)
    guard fraction > missedThreshold else { return nil }

    let target = Int((Double(currentIntervalMinutes) * 1.5).rounded(.up))
    if let next = ladder.first(where: { $0 >= target && $0 > currentIntervalMinutes }) {
      let suggestion = CadenceSuggestion(
        kind: .longerInterval(minutes: next), dues: dues, missedFraction: fraction)
      return suggestion.dismissKey == dismissedKey ? nil : suggestion
    }
    if !hasLongBreaks {
      let suggestion = CadenceSuggestion(
        kind: .addLongBreaks, dues: dues, missedFraction: fraction)
      return suggestion.dismissKey == dismissedKey ? nil : suggestion
    }
    return nil
  }
}
