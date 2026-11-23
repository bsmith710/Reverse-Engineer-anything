import AppIntents
import SelectaCore

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// Exposes the action library to Shortcuts, Siri, Spotlight, and (on iPhone) the Action button.
struct TextActionEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Selecta Action"
  static let defaultQuery = TextActionQuery()

  let id: UUID
  let name: String
  let icon: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
  }
}

struct TextActionQuery: EntityQuery {
  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [TextActionEntity] {
    SelectaModel().actions.filter { identifiers.contains($0.id) }.map(Self.entity)
  }

  @MainActor
  func suggestedEntities() async throws -> [TextActionEntity] {
    SelectaModel().actions
      .filter { $0.isEnabled && PlatformCapabilities.current.supports($0.kind) && $0.builtIn?.requiresEditableTarget != true }
      .map(Self.entity)
  }

  static func entity(_ a: TextAction) -> TextActionEntity {
    TextActionEntity(id: a.id, name: a.name, icon: a.icon)
  }
}

struct RunTextActionIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Selecta Action"
  static let description = IntentDescription("Runs a Selecta action on text and returns the result.")

  @Parameter(title: "Action") var action: TextActionEntity
  @Parameter(title: "Text", description: "Leave empty to use the clipboard.") var text: String?
  @Parameter(title: "Copy result to clipboard", default: true) var copyResult: Bool

  static var parameterSummary: some ParameterSummary {
    Summary("Run \(\.$action) on \(\.$text)") { \.$copyResult }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let model = SelectaModel()
    guard let selected = model.actions.first(where: { $0.id == action.id }) else {
      throw SelectaError.executorUnavailable(.builtIn)
    }
    let input = text ?? Clipboard.read() ?? ""
    let outcome = try await model.run(selected, on: SelectionContext(text: input, sourceAppName: "Shortcuts", isEditable: false))
    switch outcome {
    case .text(let output, _):
      if copyResult { Clipboard.write(output) }
      return .result(value: output)
    case .host(.copy(let s)), .host(.cut(let s)):
      Clipboard.write(s)
      return .result(value: s)
    case .host(.openURL(let url)):
      return .result(value: url.absoluteString)
    case .host:
      return .result(value: input)
    }
  }
}

struct SelectaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: RunTextActionIntent(),
      phrases: ["Run \(.applicationName) action", "Transform clipboard with \(.applicationName)"],
      shortTitle: "Run Action", systemImageName: "text.cursor")
  }
}

extension SelectaError: CustomLocalizedStringResourceConvertible {
  public var localizedStringResource: LocalizedStringResource { "\(description)" }
}

enum Clipboard {
  @MainActor static func read() -> String? {
    #if canImport(UIKit)
      UIPasteboard.general.string
    #else
      NSPasteboard.general.string(forType: .string)
    #endif
  }

  @MainActor static func write(_ s: String) {
    #if canImport(UIKit)
      UIPasteboard.general.string = s
    #else
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(s, forType: .string)
    #endif
  }
}
