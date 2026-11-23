import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A text-in, text-out model.
public protocol AIClient: Sendable {
  /// Whether this source keeps the text on the device.
  var isOnDevice: Bool { get }
  func complete(system: String, prompt: String) async throws -> String
}

/// Configured AI source. API keys are stored separately (Keychain) and injected at construction.
public enum AISource: Codable, Sendable, Hashable {
  /// Apple Intelligence via the Foundation Models framework (on device).
  case appleIntelligence
  /// Any OpenAI-compatible `/chat/completions` endpoint: OpenAI, OpenRouter, Groq, DeepSeek,
  /// Perplexity, LM Studio, or Ollama (`http://localhost:11434/v1`).
  case openAICompatible(baseURL: URL, model: String)
  /// Anthropic Messages API.
  case anthropic(model: String)

  public var isOnDevice: Bool {
    switch self {
    case .appleIntelligence: true
    case .openAICompatible(let url, _): url.host == "localhost" || url.host == "127.0.0.1"
    case .anthropic: false
    }
  }
}

/// Shared HTTP transport so request building and parsing can be tested without the network.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
  public init() {}
  public func send(_ request: URLRequest) async throws -> (Data, Int) {
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }
}

public struct OpenAICompatibleClient: AIClient {
  public var baseURL: URL
  public var model: String
  public var apiKey: String?
  public var transport: HTTPTransport
  public var isOnDevice: Bool { AISource.openAICompatible(baseURL: baseURL, model: model).isOnDevice }

  public init(baseURL: URL, model: String, apiKey: String?, transport: HTTPTransport = URLSessionTransport()) {
    self.baseURL = baseURL
    self.model = model
    self.apiKey = apiKey
    self.transport = transport
  }

  public func makeRequest(system: String, prompt: String) throws -> URLRequest {
    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    let body: [String: Any] = [
      "model": model,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": prompt],
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 60
    return request
  }

  public static func parse(_ data: Data) throws -> String {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = json["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String
    else { throw SelectaError.aiResponseMalformed }
    return content.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func complete(system: String, prompt: String) async throws -> String {
    let (data, status) = try await transport.send(try makeRequest(system: system, prompt: prompt))
    guard (200..<300).contains(status) else {
      throw SelectaError.aiRequestFailed(status: status, body: String(decoding: data, as: UTF8.self))
    }
    return try Self.parse(data)
  }
}

public struct AnthropicClient: AIClient {
  public var model: String
  public var apiKey: String
  public var maxTokens: Int
  public var transport: HTTPTransport
  public var isOnDevice: Bool { false }
  static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

  public init(model: String, apiKey: String, maxTokens: Int = 2048, transport: HTTPTransport = URLSessionTransport()) {
    self.model = model
    self.apiKey = apiKey
    self.maxTokens = maxTokens
    self.transport = transport
  }

  public func makeRequest(system: String, prompt: String) throws -> URLRequest {
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    let body: [String: Any] = [
      "model": model,
      "max_tokens": maxTokens,
      "system": system,
      "messages": [["role": "user", "content": prompt]],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 60
    return request
  }

  public static func parse(_ data: Data) throws -> String {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let content = json["content"] as? [[String: Any]]
    else { throw SelectaError.aiResponseMalformed }
    let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    guard !text.isEmpty else { throw SelectaError.aiResponseMalformed }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func complete(system: String, prompt: String) async throws -> String {
    let (data, status) = try await transport.send(try makeRequest(system: system, prompt: prompt))
    guard (200..<300).contains(status) else {
      throw SelectaError.aiRequestFailed(status: status, body: String(decoding: data, as: UTF8.self))
    }
    return try Self.parse(data)
  }
}

#if canImport(FoundationModels)
  import FoundationModels

  /// On-device Apple Intelligence. Requires an eligible device with Apple Intelligence enabled.
  @available(macOS 26.0, iOS 26.0, *)
  public struct AppleIntelligenceClient: AIClient {
    public var isOnDevice: Bool { true }
    public init() {}

    public static var isAvailable: Bool {
      if case .available = SystemLanguageModel.default.availability { return true }
      return false
    }

    public func complete(system: String, prompt: String) async throws -> String {
      let session = LanguageModelSession(instructions: system)
      let response = try await session.respond(to: prompt)
      return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
#endif

/// Prompts for the built-in AI actions. The selection is always sent as data, separate from the instruction.
public enum AIPrompts {
  public static let system =
    "You transform text the user selected in another app. Return only the transformed text with no preamble, quotes, or commentary unless the instruction asks for an explanation."

  public static func instruction(for action: BuiltInAction, targetLanguage: String) -> String? {
    switch action {
    case .summarize: "Summarize the text as concise bullet points."
    case .fixGrammar: "Correct grammar, spelling, and punctuation. Keep the meaning, tone, and formatting."
    case .writeFormally: "Rewrite the text in a clear, formal, professional tone."
    case .makeShorter: "Rewrite the text to be noticeably shorter while keeping the key points."
    case .explain: "Explain what this text means in plain language."
    case .translate: "Translate the text into \(targetLanguage). Preserve formatting."
    case .askAI: nil  // the user supplies the instruction
    default: nil
    }
  }

  public static func userMessage(instruction: String, text: String) -> String {
    "Instruction: \(instruction)\n\n<selected_text>\n\(text)\n</selected_text>"
  }
}
