import Foundation

/// Built-in actions. Host commands (copy/cut/paste/keys) are executed by the platform shell;
/// everything else is computed in SelectaCore.
public enum BuiltInAction: String, Codable, Sendable, CaseIterable {
  // Clipboard / host commands
  case copy, cut, paste, pastePlain
  // Case and cleanup
  case uppercase, lowercase, titleCase, sentenceCase, trimWhitespace, collapseWhitespace
  case sortLines, removeDuplicateLines
  // Encoding
  case urlEncode, urlDecode, base64Encode, base64Decode, prettyJSON
  // Counts and conversions
  case wordCount, characterCount, colorConvert, unitConvert
  // Search and links
  case webSearch, openLink, mapAddress, composeEmail
  // AI presets (use the configured AI source)
  case askAI, summarize, fixGrammar, writeFormally, makeShorter, explain, translate

  public var displayName: String {
    switch self {
    case .copy: "Copy"
    case .cut: "Cut"
    case .paste: "Paste"
    case .pastePlain: "Paste Plain"
    case .uppercase: "Uppercase"
    case .lowercase: "Lowercase"
    case .titleCase: "Title Case"
    case .sentenceCase: "Sentence case"
    case .trimWhitespace: "Trim"
    case .collapseWhitespace: "Collapse Spaces"
    case .sortLines: "Sort Lines"
    case .removeDuplicateLines: "Remove Duplicates"
    case .urlEncode: "URL Encode"
    case .urlDecode: "URL Decode"
    case .base64Encode: "Base64 Encode"
    case .base64Decode: "Base64 Decode"
    case .prettyJSON: "Format JSON"
    case .wordCount: "Word Count"
    case .characterCount: "Character Count"
    case .colorConvert: "Color"
    case .unitConvert: "Convert Units"
    case .webSearch: "Search"
    case .openLink: "Open Link"
    case .mapAddress: "Map"
    case .composeEmail: "Email"
    case .askAI: "Ask AI"
    case .summarize: "Summarize"
    case .fixGrammar: "Fix Grammar"
    case .writeFormally: "Write Formally"
    case .makeShorter: "Make Shorter"
    case .explain: "Explain"
    case .translate: "Translate"
    }
  }

  public var icon: String {
    switch self {
    case .copy: "doc.on.doc"
    case .cut: "scissors"
    case .paste, .pastePlain: "doc.on.clipboard"
    case .uppercase, .lowercase, .titleCase, .sentenceCase: "textformat"
    case .trimWhitespace, .collapseWhitespace: "text.justify.left"
    case .sortLines, .removeDuplicateLines: "list.bullet"
    case .urlEncode, .urlDecode, .base64Encode, .base64Decode: "chevron.left.forwardslash.chevron.right"
    case .prettyJSON: "curlybraces"
    case .wordCount, .characterCount: "number"
    case .colorConvert: "paintpalette"
    case .unitConvert: "ruler"
    case .webSearch: "magnifyingglass"
    case .openLink: "safari"
    case .mapAddress: "map"
    case .composeEmail: "envelope"
    case .askAI, .explain: "sparkles"
    case .summarize: "text.badge.minus"
    case .fixGrammar: "checkmark.circle"
    case .writeFormally, .makeShorter: "pencil"
    case .translate: "globe"
    }
  }

  public var defaultOutputMode: OutputMode {
    switch self {
    case .copy, .cut, .paste, .pastePlain: .none
    case .webSearch, .openLink, .mapAddress, .composeEmail: .none
    case .wordCount, .characterCount, .colorConvert, .unitConvert: .showResult
    case .askAI, .summarize, .explain, .translate: .showResult
    default: .replace
    }
  }

  /// Whether the action needs the selection to come from an editable field.
  public var requiresEditableTarget: Bool {
    switch self {
    case .cut, .paste, .pastePlain: true
    default: false
    }
  }

  /// Whether the action may send the selection off the device (subject to the AI source).
  public var usesAI: Bool {
    switch self {
    case .askAI, .summarize, .fixGrammar, .writeFormally, .makeShorter, .explain, .translate: true
    default: false
    }
  }

  /// Deterministic identifier so built-ins keep their identity across launches and devices.
  public var stableID: UUID { StableID.uuid(for: "builtin." + rawValue) }
}

enum StableID {
  /// Derives a UUID from a string with two FNV-1a passes. Not cryptographic; used only for identity.
  static func uuid(for key: String) -> UUID {
    func fnv(_ seed: UInt64) -> UInt64 {
      var hash = seed
      for byte in key.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100_0000_01b3
      }
      return hash
    }
    let a = fnv(0xcbf2_9ce4_8422_2325)
    let b = fnv(0x84222325_cbf29ce4)
    var bytes = [UInt8](repeating: 0, count: 16)
    for i in 0..<8 {
      bytes[i] = UInt8(truncatingIfNeeded: a >> (UInt64(i) * 8))
      bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (UInt64(i) * 8))
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 layout marker
    bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}
