import Foundation

/// Expected failures surfaced to the user. Each case names the failed constraint.
public enum SelectaError: Error, Equatable, Sendable, CustomStringConvertible {
  case emptySelection
  case unsupportedOnPlatform(ActionKind)
  case executorUnavailable(ActionKind)
  case invalidURLTemplate(String)
  case aiNotConfigured
  case aiRequestFailed(status: Int, body: String)
  case aiResponseMalformed
  case scriptFailed(String)
  case scriptTimedOut(seconds: Double)
  case conversionNotRecognized
  case unsupportedFileFormat(Int)

  public var description: String {
    switch self {
    case .emptySelection: "Select some text first."
    case .unsupportedOnPlatform(let kind): "\(kind.rawValue) actions are not available on this device."
    case .executorUnavailable(let kind): "No runner is configured for \(kind.rawValue) actions."
    case .invalidURLTemplate(let t): "The URL template did not produce a valid URL: \(t)"
    case .aiNotConfigured: "Choose an AI source in Settings."
    case .aiRequestFailed(let status, let body): "AI request failed (HTTP \(status)): \(body.prefix(300))"
    case .aiResponseMalformed: "The AI provider returned a response Selecta could not read."
    case .scriptFailed(let message): "Script failed: \(message)"
    case .scriptTimedOut(let seconds): "Script did not finish within \(seconds) seconds."
    case .conversionNotRecognized: "Selecta could not recognize a value to convert."
    case .unsupportedFileFormat(let v): "This action file uses format \(v), which this version cannot read."
    }
  }
}
