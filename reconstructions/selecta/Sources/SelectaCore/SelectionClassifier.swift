import Foundation

/// Observable traits of a selection, used to promote relevant actions ("smart suggestions").
public struct SelectionTraits: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let url = SelectionTraits(rawValue: 1 << 0)
  public static let email = SelectionTraits(rawValue: 1 << 1)
  public static let phone = SelectionTraits(rawValue: 1 << 2)
  public static let color = SelectionTraits(rawValue: 1 << 3)
  public static let measurement = SelectionTraits(rawValue: 1 << 4)
  public static let json = SelectionTraits(rawValue: 1 << 5)
  public static let multiline = SelectionTraits(rawValue: 1 << 6)
  public static let singleWord = SelectionTraits(rawValue: 1 << 7)
  public static let longText = SelectionTraits(rawValue: 1 << 8)
  public static let address = SelectionTraits(rawValue: 1 << 9)
  public static let base64 = SelectionTraits(rawValue: 1 << 10)
}

public enum SelectionClassifier {
  public static func traits(of raw: String) -> SelectionTraits {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return [] }
    var t: SelectionTraits = []

    if s.contains("\n") { t.insert(.multiline) }
    if !s.contains(where: \.isWhitespace) { t.insert(.singleWord) }
    if TextTransforms.wordCount(s) >= 60 { t.insert(.longText) }

    if matches(s, #"^(https?://|www\.)\S+$"#) || matches(s, #"^[a-z0-9-]+(\.[a-z0-9-]+)+(/\S*)?$"#, ci: true) {
      t.insert(.url)
    }
    if matches(s, #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, ci: true) { t.insert(.email) }
    if matches(s, #"^\+?[0-9][0-9 ().-]{6,}[0-9]$"#), s.filter(\.isNumber).count >= 7 { t.insert(.phone) }
    if ColorConverter.parse(s) != nil { t.insert(.color) }
    if UnitConverter.parse(s) != nil { t.insert(.measurement) }
    if (s.hasPrefix("{") || s.hasPrefix("[")), TextTransforms.prettyJSON(s) != nil { t.insert(.json) }
    // Street-address heuristic: house number, street word, optional ZIP. Bounded; expect misses.
    if matches(
      s,
      #"^\d{1,6}\s+[\w .'-]+\b(st|street|ave|avenue|rd|road|blvd|boulevard|dr|drive|ln|lane|way|ct|court|pkwy|parkway|hwy|highway)\b.*"#,
      ci: true)
    {
      t.insert(.address)
    }
    if t.isDisjoint(with: [.url, .email, .json]), s.count >= 16, s.count % 4 == 0 || s.hasSuffix("="),
      matches(s, #"^[A-Za-z0-9+/_-]+=*$"#), TextTransforms.base64Decode(s) != nil
    {
      t.insert(.base64)
    }
    return t
  }

  /// Built-ins that are relevant for a set of traits, most relevant first.
  public static func suggestedBuiltIns(for traits: SelectionTraits) -> [BuiltInAction] {
    var out: [BuiltInAction] = []
    if traits.contains(.url) { out.append(.openLink) }
    if traits.contains(.email) { out.append(.composeEmail) }
    if traits.contains(.address) { out.append(.mapAddress) }
    if traits.contains(.color) { out.append(.colorConvert) }
    if traits.contains(.measurement) { out.append(.unitConvert) }
    if traits.contains(.json) { out.append(.prettyJSON) }
    if traits.contains(.base64) { out.append(.base64Decode) }
    if traits.contains(.multiline) { out.append(.sortLines) }
    if traits.contains(.longText) { out.append(.summarize) }
    if traits.contains(.singleWord), traits.isDisjoint(with: [.url, .email, .color, .measurement]) {
      out.append(.explain)
    }
    return out
  }

  static func matches(_ s: String, _ pattern: String, ci: Bool = false) -> Bool {
    s.range(of: pattern, options: ci ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
  }
}

/// Orders the enabled actions for display: suggestions first, then pinned, then the user's order.
public enum ActionRanker {
  public static func rank(_ actions: [TextAction], for context: SelectionContext, maxSuggestions: Int = 2)
    -> RankedActions
  {
    let enabled = actions.filter { action in
      guard action.isEnabled else { return false }
      if action.builtIn?.requiresEditableTarget == true, !context.isEditable { return false }
      return PlatformCapabilities.current.supports(action.kind)
    }
    let traits = SelectionClassifier.traits(of: context.text)
    let wanted = SelectionClassifier.suggestedBuiltIns(for: traits)

    var suggestions: [TextAction] = []
    for action in enabled where action.triggerPattern != nil {
      if let pattern = action.triggerPattern,
        (try? Regex(pattern)) != nil,
        context.text.range(of: pattern, options: .regularExpression) != nil
      {
        suggestions.append(action)
      }
    }
    for builtIn in wanted {
      if let action = enabled.first(where: { $0.builtIn == builtIn }), !suggestions.contains(action) {
        suggestions.append(action)
      }
    }
    suggestions = Array(suggestions.prefix(maxSuggestions))

    let remaining = enabled.filter { !suggestions.contains($0) }
    let pinned = remaining.filter(\.isPinned)
    let others = remaining.filter { !$0.isPinned }
    return RankedActions(suggestions: suggestions, pinned: pinned, others: others, traits: traits)
  }
}

public struct RankedActions: Sendable, Equatable {
  public var suggestions: [TextAction]
  public var pinned: [TextAction]
  public var others: [TextAction]
  public var traits: SelectionTraits

  /// All actions in display order.
  public var ordered: [TextAction] { suggestions + pinned + others }
}
