import Foundation
import Observation
import SelectaCore
import Security

/// Identifiers shared by the app and its extensions. Change the prefix to your team's bundle ID.
enum SelectaIDs {
  static let appGroup = "group.com.example.selecta"
  static let keychainService = "com.example.selecta.ai"
}

/// The user's AI configuration. Keys live in the Keychain, never in this struct.
struct AISettings: Codable, Equatable {
  enum Provider: String, Codable, CaseIterable, Identifiable {
    case none, appleIntelligence, ollamaLocal, openAI, openRouter, anthropic, custom
    var id: String { rawValue }
    var label: String {
      switch self {
      case .none: "Off"
      case .appleIntelligence: "Apple Intelligence (on device)"
      case .ollamaLocal: "Ollama (local)"
      case .openAI: "OpenAI"
      case .openRouter: "OpenRouter"
      case .anthropic: "Anthropic"
      case .custom: "Custom OpenAI-compatible"
      }
    }
    var needsKey: Bool { ![.none, .appleIntelligence, .ollamaLocal].contains(self) }
    var defaultBaseURL: String {
      switch self {
      case .ollamaLocal: "http://localhost:11434/v1"
      case .openAI: "https://api.openai.com/v1"
      case .openRouter: "https://openrouter.ai/api/v1"
      default: ""
      }
    }
  }

  var provider: Provider = .none
  /// Model identifier as the provider names it. Left blank until the user picks one.
  var model: String = ""
  var baseURL: String = ""
  /// Off by default: no selected text leaves the device until the user turns on online actions.
  var allowOnlineActions = false
  var translationTarget = "English"
  var searchURLTemplate = "https://duckduckgo.com/?q={{url_encoded_text}}"
}

enum Keychain {
  static func set(_ value: String, account: String) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: SelectaIDs.keychainService,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    guard !value.isEmpty else { return }
    var add = base
    add[kSecValueData as String] = Data(value.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(add as CFDictionary, nil)
  }

  static func get(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: SelectaIDs.keychainService,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
}

/// App-wide state shared by the macOS app, the iOS app, and the iOS extensions.
@MainActor
@Observable
final class SelectaModel {
  var actions: [TextAction] {
    didSet { persist() }
  }
  var ai: AISettings {
    didSet { saveSettings() }
  }

  private let store: ActionStore
  private let defaults: UserDefaults
  private let cloud = NSUbiquitousKeyValueStore.default
  private static let settingsKey = "aiSettings"
  private static let cloudKey = "actions.v1"

  init() {
    let container =
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SelectaIDs.appGroup)
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Selecta")
    store = ActionStore(directory: container)
    defaults = UserDefaults(suiteName: SelectaIDs.appGroup) ?? .standard
    actions = store.load()
    if let data = defaults.data(forKey: Self.settingsKey),
      let saved = try? JSONDecoder().decode(AISettings.self, from: data)
    {
      ai = saved
    } else {
      ai = AISettings()
    }
    observeCloud()
  }

  // MARK: Running

  func makeEngine() -> ActionEngine {
    var engine = ActionEngine(
      ai: makeAIClient(),
      searchURLTemplate: ai.searchURLTemplate,
      translationTarget: ai.translationTarget)
    #if canImport(JavaScriptCore)
      engine.javaScript = JavaScriptRunner()
    #endif
    #if os(macOS)
      engine.shell = ShellRunner()
      engine.appleScript = AppleScriptRunner()
    #endif
    return engine
  }

  func ranked(for context: SelectionContext) -> RankedActions {
    ActionRanker.rank(actions, for: context)
  }

  func run(_ action: TextAction, on context: SelectionContext, instruction: String? = nil) async throws
    -> ActionOutcome
  {
    try await makeEngine().run(action, on: context, instruction: instruction)
  }

  private func makeAIClient() -> AIClient? {
    let key = Keychain.get(account: ai.provider.rawValue)
    switch ai.provider {
    case .none:
      return nil
    case .appleIntelligence:
      #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *), AppleIntelligenceClient.isAvailable {
          return AppleIntelligenceClient()
        }
      #endif
      return nil
    case .ollamaLocal:
      let url = URL(string: ai.baseURL.isEmpty ? ai.provider.defaultBaseURL : ai.baseURL)
      return url.map { OpenAICompatibleClient(baseURL: $0, model: ai.model, apiKey: nil) }
    case .openAI, .openRouter, .custom:
      guard ai.allowOnlineActions, let key, !ai.model.isEmpty else { return nil }
      let url = URL(string: ai.baseURL.isEmpty ? ai.provider.defaultBaseURL : ai.baseURL)
      return url.map { OpenAICompatibleClient(baseURL: $0, model: ai.model, apiKey: key) }
    case .anthropic:
      guard ai.allowOnlineActions, let key, !ai.model.isEmpty else { return nil }
      return AnthropicClient(model: ai.model, apiKey: key)
    }
  }

  // MARK: Editing

  func upsert(_ action: TextAction) {
    var updated = action
    updated.updatedAt = Date()
    if let index = actions.firstIndex(where: { $0.id == action.id }) {
      actions[index] = updated
    } else {
      updated.createdAt = updated.updatedAt
      actions.append(updated)
    }
  }

  func delete(_ action: TextAction) {
    actions.removeAll { $0.id == action.id }
  }

  func importAction(from url: URL) throws {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    upsert(try ActionFile.import(try Data(contentsOf: url)))
  }

  // MARK: Persistence and iCloud sync

  private func persist() {
    try? store.save(actions)
    if let data = try? ActionStore.encode(actions), data.count < 900_000 {
      cloud.set(data, forKey: Self.cloudKey)  // key-value store limit is 1 MB
    }
  }

  private func saveSettings() {
    if let data = try? JSONEncoder().encode(ai) { defaults.set(data, forKey: Self.settingsKey) }
  }

  private func observeCloud() {
    NotificationCenter.default.addObserver(
      forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.pullFromCloud() }
    }
    cloud.synchronize()
    pullFromCloud()
  }

  private func pullFromCloud() {
    guard let data = cloud.data(forKey: Self.cloudKey), let remote = try? ActionStore.decode(data) else { return }
    let merged = ActionStore.merge(local: actions, remote: remote)
    if merged != actions { actions = merged }
  }
}
