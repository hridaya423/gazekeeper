import Foundation

/// The single event vocabulary for the whole app: the scheduler emits these,
/// the stats log persists them, and the score reads them. One enum, no
/// string-to-kind translation inside the domain.
public enum BreakEventKind: String, Equatable, CaseIterable, Sendable, Codable {
  case sessionStarted = "session_started"
  case sessionEnded = "session_ended"
  /// The moment a break becomes due (legacy logs call it "heads_up_started").
  case breakDue = "break_due"
  case breakStarted = "break_started"
  case breakTaken = "break_taken"
  /// The overlay ran its full course but the user kept typing through it —
  /// the due resolved, the rest did not happen.
  case breakWorked = "break_worked"
  case breakSkipped = "break_skipped"
  case breakPostponed = "break_postponed"
  case breakInterrupted = "break_interrupted"
  case naturalBreak = "natural_break"
  case snoozeExhausted = "snooze_exhausted"
  case detectorPaused = "detector_paused"
  case detectorResumed = "detector_resumed"
  case nudgeSent = "nudge_sent"
  case menuRevealed = "menu_revealed"

  /// Decodes a persisted kind, mapping the legacy "heads_up_started" spelling.
  /// Unknown kinds throw so a corrupt or foreign line is counted as corrupt,
  /// never silently scored.
  public static func decode(_ raw: String) throws -> BreakEventKind {
    if raw == "heads_up_started" { return .breakDue }
    guard let kind = BreakEventKind(rawValue: raw) else {
      throw EventLogDecodeError.missingField("kind")
    }
    return kind
  }
}

public struct LoggedEvent: Equatable, Codable, Sendable {
  public let kind: BreakEventKind
  public let reason: String?
  public let at: Date
  public let durationSeconds: Double

  public init(
    kind: BreakEventKind, reason: String? = nil, at: Date, durationSeconds: Double = 0
  ) {
    self.kind = kind
    self.reason = reason
    self.at = at
    self.durationSeconds = durationSeconds
  }

  private enum CodingKeys: String, CodingKey {
    case kind, reason, at, durationSeconds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard let rawKind = try container.decodeIfPresent(String.self, forKey: .kind),
      !rawKind.isEmpty
    else {
      throw EventLogDecodeError.missingField("kind")
    }
    kind = try BreakEventKind.decode(rawKind)
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
    if let epoch = try? container.decode(Double.self, forKey: .at) {
      guard epoch > 0 else { throw EventLogDecodeError.missingField("at") }
      at = Date(timeIntervalSince1970: epoch)
    } else if let iso = try container.decodeIfPresent(String.self, forKey: .at) {
      if let parsed = Self.fractionalDecoder.date(from: iso) ?? Self.decoder.date(from: iso) {
        at = parsed
      } else if let epoch = TimeInterval(iso), epoch > 0 {
        at = Date(timeIntervalSince1970: epoch)
      } else {
        throw EventLogDecodeError.missingField("at")
      }
    } else {
      throw EventLogDecodeError.missingField("at")
    }
    durationSeconds =
      (try? container.decodeIfPresent(Double.self, forKey: .durationSeconds)) ?? nil ?? 0
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind.rawValue, forKey: .kind)
    try container.encodeIfPresent(reason, forKey: .reason)
    if durationSeconds != 0 {
      try container.encode(durationSeconds, forKey: .durationSeconds)
    }
    try container.encode(Self.encoder.string(from: at), forKey: .at)
  }

  // ISO8601DateFormatter is not documented thread-safe, so each call site
  // builds its own — cheap at event-write rates, and no shared mutable
  // state can race across the io queue and the caller's thread.
  static var encoder: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }

  static var decoder: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }

  static var fractionalDecoder: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFractionalSeconds, .withInternetDateTime]
    return formatter
  }
}

enum EventLogDecodeError: Error {
  case missingField(String)
}

public final class EventLog: @unchecked Sendable {

  public static let fileName = "stats.jsonl"

  private let lock = NSLock()
  private let directory: URL
  private let fileManager: FileManager
  /// Serial queue that owns all file appends so callers never block on disk.
  /// Enqueue order matches storage order because the enqueue happens while
  /// the lock is held.
  private let ioQueue = DispatchQueue(label: "gazekeeper.eventlog.io")
  private var storage: [LoggedEvent] = []
  private var corruptStorage = 0

  public init(directory: URL, fileManager: FileManager = .default) {
    self.directory = directory
    self.fileManager = fileManager
  }

  public var fileURL: URL {
    directory.appendingPathComponent(Self.fileName)
  }

  public var entries: [LoggedEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  public var corruptLineCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return corruptStorage
  }

  public func loadFromDisk() {
    ioQueue.sync {}
    lock.lock()
    defer { lock.unlock() }
    storage = []
    corruptStorage = 0
    guard let data = try? Data(contentsOf: fileURL) else { return }
    for line in splitLines(data) where !line.isEmpty {
      do {
        let event = try JSONDecoder().decode(LoggedEvent.self, from: line)
        storage.append(event)
      } catch {
        corruptStorage += 1
      }
    }
  }

  public func append(_ event: LoggedEvent) {
    lock.lock()
    storage.append(event)
    ioQueue.async { [self] in
      persist(event)
    }
    lock.unlock()
  }

  /// Blocks until every queued write has landed. Called on the quit path so
  /// the session_end event (and anything before it) is durable before exit.
  public func flush() {
    ioQueue.sync {}
  }

  private func persist(_ event: LoggedEvent) {
    do {
      if !fileManager.fileExists(atPath: directory.path) {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      var line = try JSONEncoder().encode(event)
      line.append(0x0A)
      let handle: FileHandle
      if fileManager.fileExists(atPath: fileURL.path) {
        handle = try FileHandle(forWritingTo: fileURL)
      } else {
        fileManager.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
      }
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } catch {
      NSLog("GazeKeeper failed to append to stats.jsonl: \(error)")
    }
  }

  private func splitLines(_ data: Data) -> [Data] {
    var lines: [Data] = []
    var current = Data()
    for byte in data {
      if byte == 0x0A {
        lines.append(current)
        current = Data()
      } else {
        current.append(byte)
      }
    }
    if !current.isEmpty {
      lines.append(current)
    }
    return lines
  }
}

// MARK: - Export

extension EventLog {
  /// One row per event: `timestamp,kind,reason`. ISO8601 stamps, reason
  /// quoted only when it carries CSV-hostile characters.
  public func exportCSV() -> String {
    var out = "timestamp,kind,reason\n"
    let encoder = LoggedEvent.encoder
    for event in entries {
      let reason = event.reason.map(Self.csvField) ?? ""
      out += "\(encoder.string(from: event.at)),\(event.kind.rawValue),\(reason)\n"
    }
    return out
  }

  /// `[LoggedEvent]` as sorted-key pretty JSON — byte-stable so a seeded
  /// log exports identically on every machine.
  public func exportJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(entries)
  }

  private static func csvField(_ raw: String) -> String {
    guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") else {
      return raw
    }
    return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
