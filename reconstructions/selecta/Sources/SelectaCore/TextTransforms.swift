import Foundation

/// Pure text transformations used by built-in actions.
public enum TextTransforms {
  /// Small words kept lowercase in title case unless first or last.
  static let minorWords: Set<String> = [
    "a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on", "or", "per", "the",
    "to", "vs", "via",
  ]

  public static func titleCase(_ s: String) -> String {
    let words = s.split(separator: " ", omittingEmptySubsequences: false)
    let lastIndex = words.lastIndex(where: { !$0.isEmpty }) ?? 0
    return words.enumerated().map { index, word -> String in
      let lower = word.lowercased()
      if word.isEmpty { return "" }
      // Preserve acronyms and mixed-case identifiers such as "NASA" or "iPhone".
      if word.count > 1, word.dropFirst().contains(where: \.isUppercase) { return String(word) }
      if index != 0, index != lastIndex, minorWords.contains(lower) { return lower }
      return lower.prefix(1).uppercased() + lower.dropFirst()
    }.joined(separator: " ")
  }

  public static func sentenceCase(_ s: String) -> String {
    var result = ""
    var capitalizeNext = true
    for ch in s.lowercased() {
      if capitalizeNext, ch.isLetter {
        result += ch.uppercased()
        capitalizeNext = false
      } else {
        result.append(ch)
      }
      if ".!?\n".contains(ch) { capitalizeNext = true }
    }
    return result
  }

  public static func collapseWhitespace(_ s: String) -> String {
    s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func lines(_ s: String) -> [Substring] {
    s.split(separator: "\n", omittingEmptySubsequences: false)
  }

  public static func sortLines(_ s: String) -> String {
    lines(s).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
  }

  public static func removeDuplicateLines(_ s: String) -> String {
    var seen = Set<Substring>()
    return lines(s).filter { seen.insert($0).inserted }.joined(separator: "\n")
  }

  public static func wordCount(_ s: String) -> Int {
    // A word is a run of letters/digits; inner apostrophes and hyphens ("it's", "co-op") stay in the word.
    // Platform-neutral on purpose: Foundation's .byWords is unavailable outside Apple platforms.
    var count = 0
    var inWord = false
    var previousWasJoiner = false
    for ch in s {
      if ch.isLetter || ch.isNumber {
        if !inWord { count += 1 }
        inWord = true
        previousWasJoiner = false
      } else if inWord, !previousWasJoiner, ch == "'" || ch == "’" || ch == "-" {
        previousWasJoiner = true
      } else {
        inWord = false
        previousWasJoiner = false
      }
    }
    return count
  }

  /// Counts user-perceived characters (grapheme clusters), so an emoji counts once.
  public static func characterCount(_ s: String) -> Int { s.count }

  public static func countSummary(_ s: String) -> String {
    let words = wordCount(s)
    let chars = characterCount(s)
    return "\(chars) \(chars == 1 ? "char" : "chars") • \(words) \(words == 1 ? "word" : "words")"
  }

  public static func base64Decode(_ s: String) -> String? {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    guard let data = Data(base64Encoded: t) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func prettyJSON(_ s: String) -> String? {
    guard let data = s.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    else { return nil }
    return String(data: pretty, encoding: .utf8)
  }
}
