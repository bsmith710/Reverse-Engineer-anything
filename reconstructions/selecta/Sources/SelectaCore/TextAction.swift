import Foundation

/// How an action produces its result.
public enum ActionKind: String, Codable, Sendable, CaseIterable {
  /// A built-in transformation or host command identified by `builtIn`.
  case builtIn
  /// An AI prompt; `template` is the instruction, the selection is the input.
  case aiPrompt
  /// A URL template opened in the default browser or target app.
  case url
  /// A JavaScript body that receives `text` and returns a value.
  case javaScript
  /// A shell command (macOS only). The selection arrives on stdin and in `$SELECTA_TEXT`.
  case shell
  /// An AppleScript source (macOS only). The selection is passed as the run handler's argument.
  case appleScript
  /// A Shortcuts shortcut name, run with the selection as input.
  case shortcut
}

/// Where the result of an action goes.
public enum OutputMode: String, Codable, Sendable, CaseIterable {
  /// Replace the selection in the source app (falls back to `copy` where replacement is impossible).
  case replace
  /// Put the result on the clipboard.
  case copy
  /// Show the result in a popup with Copy/Replace buttons.
  case showResult
  /// Discard any output (side-effect actions such as opening a URL).
  case none
}

/// A user-visible action that operates on selected text.
public struct TextAction: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  /// SF Symbol name.
  public var icon: String
  public var kind: ActionKind
  /// Set when `kind == .builtIn`.
  public var builtIn: BuiltInAction?
  /// Prompt, URL template, script body, or shortcut name, depending on `kind`.
  public var template: String
  public var outputMode: OutputMode
  public var isPinned: Bool
  public var isEnabled: Bool
  /// Optional regular expression; when it matches the selection the action is suggested first.
  public var triggerPattern: String?
  /// Optional group label used to fold actions into a submenu.
  public var group: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    icon: String,
    kind: ActionKind,
    builtIn: BuiltInAction? = nil,
    template: String = "",
    outputMode: OutputMode,
    isPinned: Bool = false,
    isEnabled: Bool = true,
    triggerPattern: String? = nil,
    group: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 0),
    updatedAt: Date = Date(timeIntervalSince1970: 0)
  ) {
    self.id = id
    self.name = name
    self.icon = icon
    self.kind = kind
    self.builtIn = builtIn
    self.template = template
    self.outputMode = outputMode
    self.isPinned = isPinned
    self.isEnabled = isEnabled
    self.triggerPattern = triggerPattern
    self.group = group
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// Built-in action with a stable identifier derived from its case name.
  public static func builtIn(_ action: BuiltInAction, pinned: Bool = false, group: String? = nil)
    -> TextAction
  {
    TextAction(
      id: action.stableID,
      name: action.displayName,
      icon: action.icon,
      kind: .builtIn,
      builtIn: action,
      outputMode: action.defaultOutputMode,
      isPinned: pinned,
      group: group
    )
  }
}

/// File envelope for sharing a single action (`.selecta` files).
public struct ActionFile: Codable, Sendable {
  public static let currentFormat = 1
  public var format: Int
  public var action: TextAction

  public init(action: TextAction) {
    self.format = Self.currentFormat
    self.action = action
  }

  /// Encodes an action for export.
  public static func export(_ action: TextAction) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(ActionFile(action: action))
  }

  /// Decodes an imported action and gives it a fresh identity so it never overwrites an existing one.
  public static func `import`(_ data: Data, now: Date = Date()) throws -> TextAction {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let file = try decoder.decode(ActionFile.self, from: data)
    guard file.format <= currentFormat else {
      throw SelectaError.unsupportedFileFormat(file.format)
    }
    var action = file.action
    action.id = UUID()
    action.createdAt = now
    action.updatedAt = now
    return action
  }
}
