import Foundation

/// Persists the action list as JSON. Pass an App Group container URL so the app and its extensions
/// share one library.
public final class ActionStore: @unchecked Sendable {
  public let fileURL: URL
  private let lock = NSLock()

  public init(directory: URL) {
    self.fileURL = directory.appendingPathComponent("actions.json")
  }

  /// The starter library: a short main bar with the rest grouped.
  public static let defaultActions: [TextAction] = [
    .builtIn(.copy, pinned: true),
    .builtIn(.paste, pinned: true),
    .builtIn(.webSearch, pinned: true),
    .builtIn(.askAI, pinned: true, group: "AI"),
    .builtIn(.summarize, group: "AI"),
    .builtIn(.fixGrammar, group: "AI"),
    .builtIn(.writeFormally, group: "AI"),
    .builtIn(.makeShorter, group: "AI"),
    .builtIn(.explain, group: "AI"),
    .builtIn(.translate, group: "AI"),
    .builtIn(.cut),
    .builtIn(.pastePlain),
    .builtIn(.openLink),
    .builtIn(.composeEmail),
    .builtIn(.mapAddress),
    .builtIn(.uppercase, group: "Text"),
    .builtIn(.lowercase, group: "Text"),
    .builtIn(.titleCase, group: "Text"),
    .builtIn(.sentenceCase, group: "Text"),
    .builtIn(.trimWhitespace, group: "Text"),
    .builtIn(.collapseWhitespace, group: "Text"),
    .builtIn(.sortLines, group: "Text"),
    .builtIn(.removeDuplicateLines, group: "Text"),
    .builtIn(.wordCount, group: "Info"),
    .builtIn(.colorConvert, group: "Info"),
    .builtIn(.unitConvert, group: "Info"),
    .builtIn(.urlEncode, group: "Code"),
    .builtIn(.urlDecode, group: "Code"),
    .builtIn(.base64Encode, group: "Code"),
    .builtIn(.base64Decode, group: "Code"),
    .builtIn(.prettyJSON, group: "Code"),
  ]

  public func load() -> [TextAction] {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try? Data(contentsOf: fileURL), let actions = try? Self.decode(data) else {
      return Self.defaultActions
    }
    return Self.mergingNewBuiltIns(into: actions)
  }

  public func save(_ actions: [TextAction]) throws {
    lock.lock()
    defer { lock.unlock() }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.encode(actions).write(to: fileURL, options: .atomic)
  }

  public static func encode(_ actions: [TextAction]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(actions)
  }

  public static func decode(_ data: Data) throws -> [TextAction] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([TextAction].self, from: data)
  }

  /// Appends built-ins introduced by an update without touching the user's order or settings.
  public static func mergingNewBuiltIns(into actions: [TextAction]) -> [TextAction] {
    let existing = Set(actions.map(\.id))
    return actions + defaultActions.filter { !existing.contains($0.id) }.map {
      var a = $0
      a.isEnabled = false  // new built-ins arrive hidden so the bar does not change underneath the user
      return a
    }
  }

  /// Last-writer-wins merge for sync: union by id, keeping the most recently updated copy.
  /// Order follows `local`, with remote-only actions appended.
  public static func merge(local: [TextAction], remote: [TextAction]) -> [TextAction] {
    let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
    var merged = local.map { action -> TextAction in
      guard let other = remoteByID[action.id], other.updatedAt > action.updatedAt else { return action }
      return other
    }
    let localIDs = Set(local.map(\.id))
    merged += remote.filter { !localIDs.contains($0.id) }
    return merged
  }
}
