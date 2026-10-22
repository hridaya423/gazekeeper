import AppKit
import Foundation
import GazeKeeperCore
import UniformTypeIdentifiers

/// The dashboard's Export… menu — an NSSavePanel that writes the event
/// log as CSV or JSON. Formatting itself lives in `EventLog` (Core); this
/// is only the panel glue.
enum StatsExporter {
  enum Format: String, CaseIterable {
    case csv, json

    var label: String { rawValue.uppercased() }

    var fileExtension: String { rawValue }

    var contentType: UTType {
      switch self {
      case .csv: return .commaSeparatedText
      case .json: return .json
      }
    }
  }

  @MainActor
  static func export(_ log: EventLog, format: Format) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [format.contentType]
    panel.nameFieldStringValue = "gazekeeper-stats.\(format.fileExtension)"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      switch format {
      case .csv:
        try log.exportCSV().write(to: url, atomically: true, encoding: .utf8)
      case .json:
        try log.exportJSON().write(to: url, options: .atomic)
      }
    } catch {
      NSAlert(error: error).runModal()
    }
  }
}
