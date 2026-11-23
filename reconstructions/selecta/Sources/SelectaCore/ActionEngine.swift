import Foundation

/// Commands only the platform shell can perform (they touch another app or the OS).
public enum HostCommand: Equatable, Sendable {
  case copy(String)
  case cut(String)
  case paste(plainText: Bool)
  case openURL(URL)
  case runShortcut(name: String, input: String)
}

/// The result of running an action.
public enum ActionOutcome: Equatable, Sendable {
  /// Text to deliver according to `mode`.
  case text(String, mode: OutputMode)
  /// A host command the platform must execute.
  case host(HostCommand)
}

/// Runs a script body against the selection and returns its textual result.
public protocol ScriptRunner: Sendable {
  func run(script: String, input: String, timeout: Double) async throws -> String
}

/// Executes actions. Platform shells inject the executors they support; missing executors yield
/// `SelectaError.executorUnavailable` instead of a silent no-op.
public struct ActionEngine: Sendable {
  public var ai: AIClient?
  public var javaScript: ScriptRunner?
  public var shell: ScriptRunner?
  public var appleScript: ScriptRunner?
  public var capabilities: PlatformCapabilities
  public var searchURLTemplate: String
  public var mapsURLTemplate: String
  public var translationTarget: String
  public var scriptTimeout: Double
  private let resolver = TemplateResolver()

  public init(
    ai: AIClient? = nil,
    javaScript: ScriptRunner? = nil,
    shell: ScriptRunner? = nil,
    appleScript: ScriptRunner? = nil,
    capabilities: PlatformCapabilities = .current,
    searchURLTemplate: String = "https://duckduckgo.com/?q={{url_encoded_text}}",
    mapsURLTemplate: String = "https://maps.apple.com/?q={{url_encoded_text}}",
    translationTarget: String = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English",
    scriptTimeout: Double = 10
  ) {
    self.ai = ai
    self.javaScript = javaScript
    self.shell = shell
    self.appleScript = appleScript
    self.capabilities = capabilities
    self.searchURLTemplate = searchURLTemplate
    self.mapsURLTemplate = mapsURLTemplate
    self.translationTarget = translationTarget
    self.scriptTimeout = scriptTimeout
  }

  /// Runs `action` on the selection. `instruction` overrides the prompt for ask-each-time AI actions.
  public func run(_ action: TextAction, on context: SelectionContext, instruction: String? = nil) async throws
    -> ActionOutcome
  {
    guard capabilities.supports(action.kind) else { throw SelectaError.unsupportedOnPlatform(action.kind) }
    let text = context.text
    if text.isEmpty, action.builtIn != .paste, action.builtIn != .pastePlain {
      throw SelectaError.emptySelection
    }

    switch action.kind {
    case .builtIn:
      guard let builtIn = action.builtIn else { throw SelectaError.executorUnavailable(.builtIn) }
      return try await runBuiltIn(builtIn, action: action, context: context, instruction: instruction)

    case .aiPrompt:
      let prompt = instruction ?? resolver.resolve(action.template, context: context)
      return .text(try await askAI(instruction: prompt, text: text), mode: action.outputMode)

    case .url:
      let resolved = resolver.resolve(action.template, context: context)
      guard let url = URL(string: resolved), url.scheme != nil else {
        throw SelectaError.invalidURLTemplate(resolved)
      }
      return .host(.openURL(url))

    case .javaScript:
      guard let runner = javaScript else { throw SelectaError.executorUnavailable(.javaScript) }
      let out = try await runner.run(script: action.template, input: text, timeout: scriptTimeout)
      return .text(out, mode: action.outputMode)

    case .shell:
      guard let runner = shell else { throw SelectaError.executorUnavailable(.shell) }
      // The selection reaches the command through stdin and $SELECTA_TEXT. Placeholders are always
      // shell-quoted here, so `{{text}}` in a command cannot inject shell syntax.
      let safeTemplate = action.template
        .replacingOccurrences(of: "{{text}}", with: "{{shell_quoted_text}}")
        .replacingOccurrences(of: "{{trimmed_text}}", with: "{{shell_quoted_text}}")
        .replacingOccurrences(of: "{{app}}", with: "")
      let command = resolver.resolve(safeTemplate, context: context)
      let out = try await runner.run(script: command, input: text, timeout: scriptTimeout)
      return .text(out, mode: action.outputMode)

    case .appleScript:
      guard let runner = appleScript else { throw SelectaError.executorUnavailable(.appleScript) }
      let out = try await runner.run(script: action.template, input: text, timeout: scriptTimeout)
      return .text(out, mode: action.outputMode)

    case .shortcut:
      return .host(.runShortcut(name: action.template, input: text))
    }
  }

  private func askAI(instruction: String, text: String) async throws -> String {
    guard let ai else { throw SelectaError.aiNotConfigured }
    return try await ai.complete(
      system: AIPrompts.system, prompt: AIPrompts.userMessage(instruction: instruction, text: text))
  }

  private func runBuiltIn(
    _ builtIn: BuiltInAction, action: TextAction, context: SelectionContext, instruction: String?
  ) async throws -> ActionOutcome {
    let text = context.text
    let mode = action.outputMode
    func out(_ s: String) -> ActionOutcome { .text(s, mode: mode) }

    switch builtIn {
    case .copy: return .host(.copy(text))
    case .cut: return .host(.cut(text))
    case .paste: return .host(.paste(plainText: false))
    case .pastePlain: return .host(.paste(plainText: true))
    case .uppercase: return out(text.uppercased())
    case .lowercase: return out(text.lowercased())
    case .titleCase: return out(TextTransforms.titleCase(text))
    case .sentenceCase: return out(TextTransforms.sentenceCase(text))
    case .trimWhitespace: return out(text.trimmingCharacters(in: .whitespacesAndNewlines))
    case .collapseWhitespace: return out(TextTransforms.collapseWhitespace(text))
    case .sortLines: return out(TextTransforms.sortLines(text))
    case .removeDuplicateLines: return out(TextTransforms.removeDuplicateLines(text))
    case .urlEncode: return out(TemplateResolver.urlQueryEncode(text))
    case .urlDecode: return out(text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text)
    case .base64Encode: return out(Data(text.utf8).base64EncodedString())
    case .base64Decode:
      guard let decoded = TextTransforms.base64Decode(text) else { throw SelectaError.conversionNotRecognized }
      return out(decoded)
    case .prettyJSON:
      guard let pretty = TextTransforms.prettyJSON(text) else { throw SelectaError.conversionNotRecognized }
      return out(pretty)
    case .wordCount, .characterCount: return out(TextTransforms.countSummary(text))
    case .colorConvert:
      guard let summary = ColorConverter.summary(text) else { throw SelectaError.conversionNotRecognized }
      return out(summary)
    case .unitConvert:
      guard let summary = UnitConverter.summary(text) else { throw SelectaError.conversionNotRecognized }
      return out(summary)
    case .webSearch: return try openTemplate(searchURLTemplate, context)
    case .mapAddress: return try openTemplate(mapsURLTemplate, context)
    case .openLink:
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
      guard let url = URL(string: candidate), url.host != nil else {
        throw SelectaError.invalidURLTemplate(trimmed)
      }
      return .host(.openURL(url))
    case .composeEmail:
      let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: "mailto:" + address) else { throw SelectaError.invalidURLTemplate(address) }
      return .host(.openURL(url))
    case .askAI:
      let prompt = instruction ?? (action.template.isEmpty ? "Answer or respond to this text." : action.template)
      return out(try await askAI(instruction: prompt, text: text))
    case .summarize, .fixGrammar, .writeFormally, .makeShorter, .explain, .translate:
      let prompt = AIPrompts.instruction(for: builtIn, targetLanguage: translationTarget) ?? ""
      return out(try await askAI(instruction: prompt, text: text))
    }
  }

  private func openTemplate(_ template: String, _ context: SelectionContext) throws -> ActionOutcome {
    let resolved = resolver.resolve(template, context: context)
    guard let url = URL(string: resolved) else { throw SelectaError.invalidURLTemplate(resolved) }
    return .host(.openURL(url))
  }
}
