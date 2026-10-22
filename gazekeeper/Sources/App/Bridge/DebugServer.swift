#if DEBUG

  import AppKit
  import Foundation
  import GazeKeeperCore
  import Network

  struct CommandResult: Encodable {
    var ok: Bool
    var result: JSONValue?
    var error: String?

    static func success(_ value: [String: JSONValue]? = nil) -> CommandResult {
      CommandResult(ok: true, result: value.map { JSONValue.object($0) }, error: nil)
    }

    static func failure(_ message: String) -> CommandResult {
      CommandResult(ok: false, result: nil, error: message)
    }
  }

  enum JSONValue: Encodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .null:
        try container.encodeNil()
      case .bool(let value):
        try container.encode(value)
      case .number(let value):
        if value.truncatingRemainder(dividingBy: 1) == 0 && abs(value) < 1e15 {
          try container.encode(Int(value))
        } else {
          try container.encode(value)
        }
      case .string(let value):
        try container.encode(value)
      case .array(let values):
        try container.encode(values)
      case .object(let values):
        try container.encode(values)
      }
    }

    static func from(any value: Any?) -> JSONValue {
      switch value {
      case nil:
        return .null
      case let flag as Bool:
        return .bool(flag)
      case let number as NSNumber:
        return .number(number.doubleValue)
      case let text as String:
        return .string(text)
      case let list as [Any]:
        return .array(list.map { JSONValue.from(any: $0) })
      case let dict as [String: Any]:
        var mapped: [String: JSONValue] = [:]
        for (key, item) in dict {
          mapped[key] = JSONValue.from(any: item)
        }
        return .object(mapped)
      default:
        return .string(String(describing: value))
      }
    }
  }

  @MainActor
  final class DebugServer {

    private let controller: AppStateController
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionBox] = [:]
    private let port: UInt16

    final class ConnectionBox: @unchecked Sendable {
      let connection: NWConnection
      var buffer = Data()

      init(connection: NWConnection) {
        self.connection = connection
      }
    }

    init(controller: AppStateController, port: Int) throws {
      self.controller = controller
      self.port = UInt16(port)

      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      guard let address = IPv4Address("127.0.0.1") else {
        throw DebugServerError.invalidLoopbackAddress
      }
      parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
        host: .ipv4(address), port: NWEndpoint.Port(integerLiteral: self.port))

      let listener = try NWListener(using: parameters)
      self.listener = listener
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in
          self?.accept(connection)
        }
      }
    }

    func start() {
      listener?.start(queue: .main)
    }

    func stop() {
      for box in connections.values {
        box.connection.cancel()
      }
      connections.removeAll()
      listener?.cancel()
      listener = nil
    }

    private func accept(_ connection: NWConnection) {
      let identifier = ObjectIdentifier(connection)
      connections[identifier] = ConnectionBox(connection: connection)
      connection.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        Task { @MainActor in
          if case .failed = state, let stored = self.connections[identifier] {
            stored.connection.cancel()
            self.connections.removeValue(forKey: identifier)
          }
        }
      }
      receive(on: identifier, connection: connection)
      connection.start(queue: .main)
    }

    private func receive(on identifier: ObjectIdentifier, connection: NWConnection) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
        [weak self, weak connection] data, _, complete, error in
        guard let self else { return }
        Task { @MainActor in
          guard let connection, let box = self.connections[identifier] else { return }
          if let data, !data.isEmpty {
            box.buffer.append(data)
            if let request = HTTPRequest.parse(box.buffer) {
              self.handleRawRequest(request, on: connection)
              return
            }
          }
          if error != nil || complete {
            self.drop(identifier: identifier, connection: connection)
          } else if box.buffer.count > Self.maxBufferBytes {
            self.respond(
              status: "400 Bad Request",
              body: ["error": .string("request too large")],
              to: connection)
          } else {
            self.receive(on: identifier, connection: connection)
          }
        }
      }
    }

    private func drop(identifier: ObjectIdentifier, connection: NWConnection) {
      connection.cancel()
      connections.removeValue(forKey: identifier)
    }

    private func handleRawRequest(_ request: HTTPRequest, on connection: NWConnection) {
      route(request, to: connection)
    }

    private static let maxBufferBytes = 1_048_576

    private func route(_ request: HTTPRequest, to connection: NWConnection) {
      switch (request.method, request.path) {
      case ("GET", "/health"):
        respond(status: "200 OK", body: ["ok": .bool(true)], to: connection)
      case ("GET", "/debug/state"):
        respond(status: "200 OK", body: buildState(), to: connection)
      case ("POST", "/debug/commands"):
        handleCommand(request.bodyJSON) { [weak self] payload, status in
          self?.respond(status: status, body: payload, to: connection)
        }
      default:
        respond(
          status: "404 Not Found",
          body: ["error": .string("unknown route \(request.method) \(request.path)")],
          to: connection)
      }
    }

    private func handleCommand(
      _ json: [String: Any]?, completion: @escaping @MainActor ([String: JSONValue], String) -> Void
    ) {
      guard let commandName = json?["cmd"] as? String ?? json?["command"] as? String else {
        completion(["ok": .bool(false), "error": .string("missing cmd")], "400 Bad Request")
        return
      }
      let args = json?["args"] as? [String: Any]
      let result = execute(commandName: commandName, args: args)
      var payload: [String: JSONValue] = [
        "cmd": .string(commandName),
        "ok": .bool(result.ok),
      ]
      if let value = result.result {
        payload["result"] = value
      }
      if let errorText = result.error {
        payload["error"] = .string(errorText)
      }
      completion(payload, result.ok ? "200 OK" : "400 Bad Request")
    }

    private func execute(commandName: String, args: [String: Any]?) -> CommandResult {
      switch commandName {
      case "fastForward":
        guard let seconds = numeric(args, "seconds") else {
          return .failure("fastForward requires seconds")
        }
        controller.fastForward(seconds: seconds)
        return .success(["advancedSeconds": .number(seconds)])
      case "setClockOffset":
        guard let seconds = numeric(args, "seconds") else {
          return .failure("setClockOffset requires seconds")
        }
        controller.setClockOffset(seconds: seconds)
        return .success(["offsetSeconds": .number(seconds)])
      case "triggerBreak":
        controller.triggerBreakNow()
        return .success()
      case "skip":
        controller.skipBreak()
        return .success()
      case "forceReduceMotion":
        guard let flag = args?["enabled"] as? Bool ?? (args?["enabled"] as? NSNumber)?.boolValue
        else {
          return .failure("forceReduceMotion requires boolean enabled")
        }
        controller.setForceReduceMotion(flag)
        return .success(["reduceMotion": .bool(controller.reduceMotionEffective)])
      case "postpone":
        let seconds = numeric(args, "seconds") ?? 300
        controller.postpone(seconds: seconds)
        return .success(["postponedBy": .number(seconds)])
      case "pause":
        controller.setPaused(byUser: true)
        return .success(["paused": .bool(true)])
      case "resume":
        controller.setPaused(byUser: false)
        return .success(["paused": .bool(false)])
      case "setSetting":
        guard let key = args?["key"] as? String else {
          return .failure("setSetting requires key")
        }
        let outcome = controller.applySetting(key: key, value: args?["value"])
        switch outcome {
        case .applied:
          return .success(["applied": .string(key)])
        case .unknownKey:
          return .failure("unknown settings key \(key)")
        case .invalidValue(let reason):
          return .failure(reason)
        case .clamped(let report):
          return .success([
            "clamped": JSONValue.from(any: [
              "requested": report.requestedValue,
              "applied": report.appliedValue,
              "reason": report.reason,
            ])
          ])
        }
      case "injectIdle":
        let seconds = numeric(args, "seconds") ?? 0
        controller.injectIdle(seconds: seconds)
        return .success(["idleSeconds": .number(seconds)])
      case "completeBreak":
        controller.completeBreakIfNeeded()
        return .success()
      case "simulateHotKey":
        HotKeyCenter.shared.simulate(.startBreak)
        NSLog("GazeKeeper simulateHotKey invoked the startBreak shortcut path")
        return .success(["phase": .string(controller.snapshot.state.phase.rawValue)])
      case "openSettings":
        AppDelegate.shared?.openSettingsWindow()
        return .success(["settingsVisible": .bool(true)])
      case "openWelcome":
        AppDelegate.shared?.openWelcomeWindow()
        return .success(["welcomeVisible": .bool(true)])
      case "openDashboard":
        AppDelegate.shared?.openDashboardWindow()
        return .success(["dashboardVisible": .bool(true)])
      case "revealMenu":
        SingleInstanceCoordinatorRevealBridge.revealForDebug()
        return .success(["menuRevealed": .bool(true)])
      case "injectFrontmostApp":
        let bundleId = args?["bundleId"] as? String ?? args?["bundleID"] as? String
        let title = args?["title"] as? String
        let fullscreen = (args?["fullscreen"] as? Bool) ?? false
        controller.injectFrontmostApp(bundleId: bundleId, title: title, fullscreen: fullscreen)
        return .success(["injected": .bool(true)])
      case "clearFrontmostInject":
        controller.clearFrontmostInject()
        return .success(["cleared": .bool(true)])
      case "quit":
        DispatchQueue.main.async { [weak controllerRef = controller] in
          controllerRef?.quitAfterFlush()
        }
        return .success()
      default:
        return .failure("unknown command \(commandName)")
      }
    }

    private func buildState() -> [String: JSONValue] {
      let snapshot = controller.snapshot
      let state = snapshot.state
      let now = controller.clock.now()

      var phaseState: [String: JSONValue] = [
        "phase": .string(state.phase.rawValue),
        "nextDue": .string(iso(state.effectiveNextDue(from: now))),
        "remainingSeconds": .number(state.effectiveRemaining(from: now)),
        "paused": .bool(state.isPaused()),
        "pausedByUser": .bool(state.pausedByUser),
        "pausedByDetector": .bool(state.pausedByDetector),
        "lastPostponeReason": state.lastPostponeReason.map { JSONValue.string($0) } ?? .null,
        "idleSeconds": .number(controller.engine.currentIdleSeconds()),
        "idleThresholdSeconds": .number(Double(GazeKeeperSettings.idleThresholdSeconds)),
        "now": .string(iso(now)),
      ]
      if let breakEndsAt = state.breakEndsAt {
        phaseState["breakEndsAt"] = .string(iso(breakEndsAt))
        let remaining =
          state.isPaused()
          ? (state.pausedRemaining ?? 0)
          : max(0, breakEndsAt.timeIntervalSince(now))
        phaseState["breakRemainingSeconds"] = .number(remaining)
      }

      var settingsPayload: [String: JSONValue] = [
        "intervalMinutes": .number(Double(snapshot.settings.intervalMinutes)),
        "breakSeconds": .number(Double(snapshot.settings.breakSeconds)),
        "headsUpSeconds": .number(Double(snapshot.settings.headsUpSeconds)),
        "cooldownSeconds": .number(Double(snapshot.settings.cooldownSeconds)),
        "allowEsc": .bool(snapshot.settings.allowEsc),
        "soundEnabled": .bool(snapshot.settings.soundEnabled),
        "launchAtLogin": .bool(snapshot.settings.launchAtLogin),
        "messages": .array(snapshot.settings.messages.map { .string($0) }),
        "officeHours": .from(any: [
          "enabled": snapshot.settings.officeHours.enabled,
          "start": snapshot.settings.officeHours.startMinuteOfDay,
          "end": snapshot.settings.officeHours.endMinuteOfDay,
          "weekdaysOnly": snapshot.settings.officeHours.weekdaysOnly,
          "days": snapshot.settings.officeHours.dayNames(),
        ]),
        "wellness": .object([
          "enabled": .bool(snapshot.settings.wellness.enabled),
          "postureMinutes": .number(Double(snapshot.settings.wellness.postureMinutes)),
          "blinkMinutes": .number(Double(snapshot.settings.wellness.blinkMinutes)),
          "quietHours": .from(any: [
            "enabled": snapshot.settings.wellness.quietHours.enabled,
            "start": snapshot.settings.wellness.quietHours.startMinuteOfDay,
            "end": snapshot.settings.wellness.quietHours.endMinuteOfDay,
          ]),
          "postureMessage": snapshot.settings.wellness.postureMessage.map { JSONValue.string($0) }
            ?? JSONValue.null,
          "blinkMessage": snapshot.settings.wellness.blinkMessage.map { JSONValue.string($0) }
            ?? JSONValue.null,
        ]),
      ]
      var detectors: [String: JSONValue] = [:]
      for (identifier, detector) in snapshot.settings.detectors.sorted(by: { $0.key < $1.key }) {
        detectors[identifier] = .from(any: [
          "enabled": detector.enabled, "sensitivity": detector.sensitivity,
        ])
      }
      settingsPayload["detectors"] = .object(detectors)

      let mergedEvents =
        (snapshot.events.suffix(100) + controller.detectorEventEntries
        + controller.nudgeEvents)
        .sorted { $0.at < $1.at }
        .suffix(100)
      let eventsPayload: [JSONValue] = mergedEvents.map { event in
        var payload: [String: JSONValue] = [
          "kind": .string(event.kind.rawValue),
          "at": .string(iso(event.at)),
        ]
        if let reason = event.reason {
          payload["reason"] = .string(reason)
        } else {
          payload["reason"] = .null
        }
        return .object(payload)
      }
      let eventTotal = controller.loggedEventCount

      let todayScore = controller.todayScore
      let scorePayload: [String: JSONValue] = [
        "total": .number(Double(todayScore.total)),
        "discipline": .number(Double(todayScore.discipline)),
        "adherence": .number(Double(todayScore.adherence)),
        "breaksDue": .number(Double(todayScore.breaksDue)),
        "breaksTaken": .number(Double(todayScore.breaksTaken)),
        "breaksSkipped": .number(Double(todayScore.breaksSkipped)),
        "breaksPostponed": .number(Double(todayScore.breaksPostponed)),
      ]

      let seriesPayload: [JSONValue] = controller.scoreSeries.map { point in
        .object([
          "date": .string(dayKey(point.date, calendar: .current)),
          "total": .number(Double(point.score.total)),
          "discipline": .number(Double(point.score.discipline)),
          "adherence": .number(Double(point.score.adherence)),
        ])
      }

      let statsPayload: [String: JSONValue] = [
        "eventTotal": .number(Double(controller.loggedEventCount)),
        "logFile": .string(controller.eventLog.fileURL.path),
        "today": .object(scorePayload),
        "series": .array(seriesPayload),
      ]

      var detectorsState: [String: JSONValue] = [:]
      for identifier in ["camera", "microphone", "screenSharing", "fullscreen"] {
        var entry: [String: JSONValue] = [:]
        let pausedDecision = controller.engine.detectorDecisions.first {
          $0.detectorID == identifier && $0.action == .paused
        }
        entry["active"] = .bool(pausedDecision != nil)
        if let decision = controller.engine.detectorDecisions.first(
          where: { $0.detectorID == identifier })
        {
          entry["lastAction"] = .string(decision.action == .paused ? "paused" : "resumed")
          entry["lastDecisionAt"] = .string(iso(decision.at))
        }
        detectorsState[identifier] = .object(entry)
      }

      var wellnessState: [String: JSONValue] = [:]
      let cadence = controller.engine.wellnessSnapshot
      let cadenceNow = controller.clock.now()
      for (kind, nextAt, lastAt, count) in [
        ("posture", cadence.nextPostureAt, cadence.lastPostureAt, cadence.sentPostureCount),
        ("blink", cadence.nextBlinkAt, cadence.lastBlinkAt, cadence.sentBlinkCount),
      ] {
        var entry: [String: JSONValue] = [
          "nextNudgeAt": .string(iso(nextAt)),
          "secondsUntilNext": .number(max(0, nextAt.timeIntervalSince(cadenceNow))),
          "sentCount": .number(Double(count)),
        ]
        if let lastAt {
          entry["lastNudgeAt"] = .string(iso(lastAt))
        }
        wellnessState[kind] = .object(entry)
      }
      wellnessState["enabled"] = .bool(cadence.enabled)

      let trayPayload: [String: JSONValue] = [
        "canStartBreakNow": .bool(controller.trayMenuState.canStartBreakNow),
        "canPostpone": .bool(controller.trayMenuState.canPostpone),
        "pauseActionTitle": .string(controller.trayMenuState.pauseActionTitle),
        "pausedByUser": .bool(controller.trayMenuState.pausedByUser),
      ]

      return [
        "state": .object(phaseState),
        "settings": .object(settingsPayload),
        "events": .array(eventsPayload),
        "eventTotal": .number(Double(eventTotal)),
        "stats": .object(statsPayload),
        "score": .object(scorePayload),
        "detectors": .object(detectorsState),
        "wellness": .object(wellnessState),
        "tray": .object(trayPayload),
        "overlay": buildOverlayState(),
      ]
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
      let components = calendar.dateComponents([.year, .month, .day], from: date)
      return String(
        format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0,
        components.day ?? 0)
    }

    private func buildOverlayState() -> JSONValue {
      let model = controller.overlayModel
      var payload: [String: JSONValue] = [
        "visible": .bool(model.isPresented && controller.isOverlayVisible),
        "remainingSeconds": .number(Double(model.remainingSeconds)),
        "totalSeconds": .number(Double(model.totalSeconds)),
        "progress": .number(model.progress),
        "message": .string(model.message),
        "allowEsc": .bool(model.allowEsc),
        "reduceMotion": .bool(model.reduceMotion),
      ]
      if let screen = NSScreen.screens.first {
        let screenFrame = screen.frame
        payload["screenWidth"] = .number(screenFrame.width)
        payload["screenHeight"] = .number(screenFrame.height)
        if let windowFrame = controller.overlayFrame {
          payload["windowWidth"] = .number(windowFrame.width)
          payload["windowHeight"] = .number(windowFrame.height)
          payload["coversPrimaryScreen"] = .bool(
            controller.isOverlayVisible && windowFrame.width >= screenFrame.width
              && windowFrame.height >= screenFrame.height)
        } else {
          payload["coversPrimaryScreen"] = .bool(
            controller.isOverlayVisible
              && screenFrame.width > 0 && screenFrame.height > 0)
        }
      }
      return .object(payload)
    }

    private func respond(status: String, body: [String: JSONValue], to connection: NWConnection) {
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(JSONValue.object(body))
        let header =
          "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(
          content: response,
          completion: .contentProcessed { [weak self, weak connection] _ in
            Task { @MainActor in
              if let connection {
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
              }
              connection?.cancel()
            }
          })
      } catch {
        NSLog("GazeKeeper debug response encode failure: \(error)")
        connection.cancel()
      }
    }

    private func numeric(_ args: [String: Any]?, _ key: String) -> Double? {
      guard let raw = args?[key] else { return nil }
      if let number = raw as? Double { return number }
      if let number = raw as? NSNumber { return number.doubleValue }
      if let text = raw as? String { return Double(text) }
      return nil
    }

    private func iso(_ date: Date) -> String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter.string(from: date)
    }
  }

  enum DebugServerError: Error {
    case invalidLoopbackAddress
  }

  struct HTTPRequest {
    let method: String
    let path: String
    let contentLength: Int?
    let bodyJSON: [String: Any]?

    static func parse(_ data: Data) -> HTTPRequest? {
      guard let headEndRange = data.range(of: Data("\r\n\r\n".utf8)) else {
        return nil
      }
      let headData = data.subdata(in: data.startIndex..<headEndRange.lowerBound)
      let bodyData = data.subdata(in: headEndRange.upperBound..<data.endIndex)
      guard let request = build(headData: headData, bodyData: bodyData) else { return nil }
      if let contentLength = request.contentLength,
        contentLength > 0,
        bodyData.count < contentLength
      {
        return nil
      }
      return request
    }

    private static func build(headData: Data, bodyData: Data) -> HTTPRequest? {
      guard let head = String(data: headData, encoding: .utf8) else { return nil }
      let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
      guard let requestLine = lines.first else { return nil }
      let parts = requestLine.split(separator: " ")
      guard parts.count >= 2 else { return nil }

      var contentLength: Int?
      for line in lines.dropFirst() {
        let lowered = line.lowercased()
        if lowered.hasPrefix("content-length:") {
          contentLength =
            Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
      }

      var body: [String: Any]?
      if let length = contentLength, length > 0, !bodyData.isEmpty {
        body =
          try? JSONSerialization.jsonObject(with: bodyData.prefix(length)) as? [String: Any]
      }
      return HTTPRequest(
        method: String(parts[0]), path: normalize(String(parts[1])),
        contentLength: contentLength, bodyJSON: body)
    }

    private static func normalize(_ rawPath: String) -> String {
      guard let queryStart = rawPath.firstIndex(of: "?") else { return rawPath }
      return String(rawPath[rawPath.startIndex..<queryStart])
    }
  }

#endif
