import Foundation
import GazeKeeperCore

enum DataLocations {

  static func resolveDataDirectory(commandLine: [String] = CommandLine.arguments) -> URL {
    if let index = commandLine.firstIndex(of: "--gk-data-dir"), index + 1 < commandLine.count {
      return URL(fileURLWithPath: commandLine[index + 1], isDirectory: true)
    }
    if let flag = commandLine.first(where: { $0.hasPrefix("--gk-data-dir=") }) {
      let path = String(flag.dropFirst("--gk-data-dir=".count))
      if !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    }
    return defaultDirectory()
  }

  static func resolveDebugPort(commandLine: [String] = CommandLine.arguments) -> Int? {
    if let index = commandLine.firstIndex(of: "--gk-debug-port"), index + 1 < commandLine.count,
      let port = Int(commandLine[index + 1])
    {
      return validDebugPort(port)
    }
    if let flag = commandLine.first(where: { $0.hasPrefix("--gk-debug-port=") }) {
      if let port = Int(flag.dropFirst("--gk-debug-port=".count)) {
        return validDebugPort(port)
      }
    }
    return nil
  }

  static func isValidDebugPort(_ port: Int) -> Bool {
    (3110...3119).contains(port)
  }

  static func resolveForceReduceMotion(commandLine: [String] = CommandLine.arguments) -> Bool {
    commandLine.contains("--gk-reduce-motion")
      || commandLine.contains(where: { $0.hasPrefix("--gk-reduce-motion=") })
  }

  private static func validDebugPort(_ port: Int) -> Int? {
    isValidDebugPort(port) ? port : nil
  }

  static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    return base.appendingPathComponent("GazeKeeper", isDirectory: true)
  }
}
