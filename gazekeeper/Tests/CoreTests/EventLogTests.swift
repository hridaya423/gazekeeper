import XCTest

@testable import GazeKeeperCore

final class EventLogTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("gk-eventlog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeEvent(
    _ kind: BreakEventKind, reason: String? = nil, at: Date = Date(timeIntervalSince1970: 1_000)
  ) -> LoggedEvent {
    LoggedEvent(kind: kind, reason: reason, at: at)
  }

  func testAppendWritesOneJSONLinePerEvent() throws {
    let log = EventLog(directory: directory)
    log.append(makeEvent(.breakTaken))
    log.append(makeEvent(.breakSkipped, reason: "user"))
    log.flush()

    let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
    let lines = contents.split(separator: "\n")
    XCTAssertEqual(lines.count, 2)

    let reloaded = EventLog(directory: directory)
    reloaded.loadFromDisk()
    XCTAssertEqual(reloaded.entries.count, 2)
    XCTAssertEqual(reloaded.entries[0].kind.rawValue, "break_taken")
    XCTAssertEqual(reloaded.entries[1].kind.rawValue, "break_skipped")
    XCTAssertEqual(reloaded.entries[1].reason, "user")
  }

  func testFlushMakesAppendsDurableOnDisk() throws {
    let log = EventLog(directory: directory)
    let stamp = Date(timeIntervalSince1970: 1_756_000_000)
    log.append(makeEvent(.breakTaken, at: stamp))
    log.flush()

    let raw = try String(contentsOf: log.fileURL, encoding: .utf8)
    XCTAssertTrue(raw.hasSuffix("\n"))
    XCTAssertTrue(raw.contains("break_taken"))
  }

  func testEntriesReflectAppendsBeforeFlush() {
    let log = EventLog(directory: directory)
    log.append(makeEvent(.breakTaken))

    XCTAssertEqual(log.entries.map(\.kind.rawValue), ["break_taken"])
  }

  func testAppendsPersistInSubmissionOrder() throws {
    let log = EventLog(directory: directory)
    for index in 0..<50 {
      log.append(
        makeEvent(.breakTaken, reason: "r\(index)", at: Date(timeIntervalSince1970: Double(index))))
    }
    log.flush()

    let reloaded = EventLog(directory: directory)
    reloaded.loadFromDisk()
    XCTAssertEqual(reloaded.entries.map(\.reason), (0..<50).map { "r\($0)" })
  }

  func testLoadParsesIsoTimestampsWithSubSecondPrecision() throws {
    let url = directory.appendingPathComponent("stats.jsonl")
    try Data("{\"kind\":\"break_taken\",\"at\":\"2026-08-24T12:00:00.250Z\"}\n".utf8)
      .write(to: url)

    let log = EventLog(directory: directory)
    log.loadFromDisk()

    XCTAssertEqual(log.entries.count, 1)
    XCTAssertEqual(
      log.entries[0].at.timeIntervalSince1970,
      Date(timeIntervalSince1970: 1_787_572_800.25).timeIntervalSince1970,
      accuracy: 0.001)
  }

  func testLoadAcceptsEpochFallbackTimestamps() throws {
    let url = directory.appendingPathComponent("stats.jsonl")
    try Data("{\"kind\":\"break_taken\",\"at\":7200,\"reason\":\"user\"}\n".utf8).write(to: url)

    let log = EventLog(directory: directory)
    log.loadFromDisk()

    XCTAssertEqual(log.entries.count, 1)
    XCTAssertEqual(log.entries[0].at, Date(timeIntervalSince1970: 7_200))
    XCTAssertEqual(log.entries[0].reason, "user")
  }

  func testCorruptLineSkippedWhileValidEntriesIntact() throws {
    let url = directory.appendingPathComponent("stats.jsonl")
    let validA = "{\"kind\":\"break_taken\",\"at\":\"2026-08-24T09:00:00Z\"}"
    let validB = "{\"kind\":\"nudge_sent\",\"reason\":\"blink\",\"at\":\"2026-08-24T10:00:00Z\"}"
    try Data("\(validA)\n{not json at all\n\n\(validB)\n".utf8).write(to: url)

    let log = EventLog(directory: directory)
    log.loadFromDisk()

    XCTAssertEqual(log.entries.map(\.kind.rawValue), ["break_taken", "nudge_sent"])
    XCTAssertEqual(log.corruptLineCount, 1)
  }

  func testLinesWithMissingKindOrTimestampAreMalformed() throws {
    let url = directory.appendingPathComponent("stats.jsonl")
    try Data(
      "{\"at\":\"2026-08-24T09:00:00Z\"}\n{\"kind\":\"break_taken\"}\n{\"kind\":\"break_taken\",\"at\":\"garbage\"}\n"
        .utf8
    ).write(to: url)

    let log = EventLog(directory: directory)
    log.loadFromDisk()

    XCTAssertTrue(log.entries.isEmpty)
    XCTAssertEqual(log.corruptLineCount, 3)
  }

  func testUnknownEventKindsCountAsCorruptLines() throws {
    let url = directory.appendingPathComponent("stats.jsonl")
    try Data(
      "{\"kind\":\"some_future_kind\",\"at\":\"2026-08-24T09:00:00Z\"}\n".utf8
    ).write(to: url)

    let log = EventLog(directory: directory)
    log.loadFromDisk()

    XCTAssertTrue(log.entries.isEmpty)
    XCTAssertEqual(log.corruptLineCount, 1)
  }

  func testLegacyHeadsUpStartedDecodesAsBreakDue() throws {
    let url = directory.appendingPathComponent("stats.jsonl")
    try Data(
      "{\"kind\":\"heads_up_started\",\"at\":\"2026-08-24T09:00:00Z\"}\n".utf8
    ).write(to: url)

    let log = EventLog(directory: directory)
    log.loadFromDisk()

    XCTAssertEqual(log.entries.map(\.kind), [.breakDue])
    XCTAssertEqual(log.corruptLineCount, 0)
  }

  func testHistorySurvivesRestartAcrossInstances() throws {
    let first = EventLog(directory: directory)
    first.append(makeEvent(.sessionStarted, at: Date(timeIntervalSince1970: 100)))
    first.append(makeEvent(.breakTaken, at: Date(timeIntervalSince1970: 200)))
    first.append(makeEvent(.sessionEnded, at: Date(timeIntervalSince1970: 300)))
    first.flush()

    let second = EventLog(directory: directory)
    second.loadFromDisk()

    XCTAssertEqual(second.entries.count, 3)
    XCTAssertEqual(
      second.entries.map(\.kind.rawValue), ["session_started", "break_taken", "session_ended"])
    XCTAssertEqual(second.corruptLineCount, 0)
  }

  func testMenuRevealedRoundTripsThroughDisk() throws {
    let log = EventLog(directory: directory)
    log.append(
      LoggedEvent(
        kind: BreakEventKind.menuRevealed, reason: "second_launch",
        at: Date(timeIntervalSince1970: 400)))
    log.flush()

    let reloaded = EventLog(directory: directory)
    reloaded.loadFromDisk()

    XCTAssertEqual(reloaded.entries.count, 1)
    XCTAssertEqual(reloaded.entries[0].kind.rawValue, "menu_revealed")
    XCTAssertEqual(reloaded.entries[0].reason, "second_launch")
  }

  func testLoadOnMissingFileYieldsEmptyHistoryWithoutCreatingIt() throws {
    let log = EventLog(directory: directory)
    log.loadFromDisk()

    XCTAssertTrue(log.entries.isEmpty)
    XCTAssertEqual(log.corruptLineCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.fileURL.path))
  }

  func testAppendCreatesMissingDirectory() throws {
    let nested = directory.appendingPathComponent("deep/sub", isDirectory: true)
    let log = EventLog(directory: nested)
    log.append(makeEvent(.breakTaken))
    log.flush()

    XCTAssertTrue(FileManager.default.fileExists(atPath: log.fileURL.path))
  }

  // MARK: - Export

  func testExportCSVIsByteExact() throws {
    let log = EventLog(directory: directory)
    log.append(
      makeEvent(.breakTaken, reason: "user", at: Date(timeIntervalSince1970: 1_000)))
    log.append(
      makeEvent(.breakSkipped, at: Date(timeIntervalSince1970: 2_000)))
    log.append(
      makeEvent(.breakPostponed, reason: "a,b \"quoted\"", at: Date(timeIntervalSince1970: 3_000)))

    let expected =
      "timestamp,kind,reason\n"
      + "1970-01-01T00:16:40.000Z,break_taken,user\n"
      + "1970-01-01T00:33:20.000Z,break_skipped,\n"
      + "1970-01-01T00:50:00.000Z,break_postponed,\"a,b \"\"quoted\"\"\"\n"
    XCTAssertEqual(log.exportCSV(), expected)
  }

  func testExportJSONRoundTripsThroughDecoder() throws {
    let log = EventLog(directory: directory)
    let seeded = [
      makeEvent(.breakDue, at: Date(timeIntervalSince1970: 1_000)),
      makeEvent(.breakTaken, reason: "user", at: Date(timeIntervalSince1970: 1_020)),
    ]
    for event in seeded { log.append(event) }

    let data = try log.exportJSON()
    let decoded = try JSONDecoder().decode([LoggedEvent].self, from: data)
    XCTAssertEqual(decoded, seeded)
  }
}
