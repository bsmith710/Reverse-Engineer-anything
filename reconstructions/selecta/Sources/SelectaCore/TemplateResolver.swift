import Foundation

/// Resolves `{{placeholder}}` tokens in action templates.
///
/// Supported tokens:
/// - `{{text}}` — the selection, unchanged
/// - `{{url_encoded_text}}` — percent-encoded for a URL query component
/// - `{{json_text}}` — a JSON string literal (with quotes)
/// - `{{shell_quoted_text}}` — a single-quoted POSIX shell word
/// - `{{applescript_text}}` — an AppleScript string literal (with quotes)
/// - `{{trimmed_text}}` — whitespace-trimmed selection
/// - `{{app}}` — the source application's name, when known
///
/// Unknown tokens are left untouched so a typo is visible in the output rather than silently dropped.
public struct TemplateResolver: Sendable {
  public init() {}

  public func resolve(_ template: String, context: SelectionContext) -> String {
    var output = ""
    var rest = Substring(template)
    while let open = rest.range(of: "{{") {
      output += rest[..<open.lowerBound]
      let afterOpen = rest[open.upperBound...]
      guard let close = afterOpen.range(of: "}}") else {
        output += rest[open.lowerBound...]
        return output
      }
      let token = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
      if let value = value(for: token, context: context) {
        output += value
      } else {
        output += rest[open.lowerBound..<close.upperBound]
      }
      rest = afterOpen[close.upperBound...]
    }
    output += rest
    return output
  }

  private func value(for token: String, context: SelectionContext) -> String? {
    let text = context.text
    switch token {
    case "text": return text
    case "trimmed_text": return text.trimmingCharacters(in: .whitespacesAndNewlines)
    case "url_encoded_text": return Self.urlQueryEncode(text)
    case "json_text": return Self.jsonLiteral(text)
    case "shell_quoted_text": return Self.shellQuote(text)
    case "applescript_text": return Self.appleScriptLiteral(text)
    case "app": return context.sourceAppName ?? ""
    default: return nil
    }
  }

  /// Percent-encodes for use inside a query component (RFC 3986 unreserved characters only).
  public static func urlQueryEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
  }

  public static func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  public static func appleScriptLiteral(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      + "\""
  }

  public static func jsonLiteral(_ s: String) -> String {
    guard let data = try? JSONEncoder().encode(s), let str = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return str
  }
}

/// What the platform knows about the current selection.
public struct SelectionContext: Sendable, Equatable {
  public var text: String
  public var sourceAppName: String?
  public var sourceBundleID: String?
  /// Whether the selection lives in an editable field (so replace/cut/paste can apply).
  public var isEditable: Bool

  public init(text: String, sourceAppName: String? = nil, sourceBundleID: String? = nil, isEditable: Bool = true) {
    self.text = text
    self.sourceAppName = sourceAppName
    self.sourceBundleID = sourceBundleID
    self.isEditable = isEditable
  }
}
