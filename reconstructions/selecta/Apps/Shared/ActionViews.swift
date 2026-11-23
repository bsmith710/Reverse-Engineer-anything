import SelectaCore
import SwiftUI
import UniformTypeIdentifiers

/// The floating pill of actions shown next to a selection (macOS panel, iOS extension and keyboard).
struct ActionBarView: View {
  let ranked: RankedActions
  let onRun: (TextAction) -> Void
  var countSummary: String?

  private var mainBar: [TextAction] {
    ranked.suggestions + ranked.pinned.filter { $0.group == nil || ranked.suggestions.contains($0) }
  }

  private var groups: [(String, [TextAction])] {
    let grouped = Dictionary(grouping: (ranked.pinned + ranked.others).filter { $0.group != nil }, by: { $0.group! })
    return grouped.keys.sorted().map { ($0, grouped[$0]!) }
  }

  private var ungroupedOthers: [TextAction] { ranked.others.filter { $0.group == nil } }

  var body: some View {
    HStack(spacing: 2) {
      ForEach(mainBar) { action in
        button(for: action, highlighted: ranked.suggestions.contains(action))
      }
      ForEach(groups, id: \.0) { name, members in
        Menu {
          ForEach(members) { action in
            Button { onRun(action) } label: { Label(action.name, systemImage: action.icon) }
          }
        } label: {
          Text(name).font(.callout.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 6)
        }
        .menuIndicator(.hidden)
        .fixedSize()
      }
      if !ungroupedOthers.isEmpty {
        Menu {
          ForEach(ungroupedOthers) { action in
            Button { onRun(action) } label: { Label(action.name, systemImage: action.icon) }
          }
        } label: {
          Image(systemName: "ellipsis").padding(.horizontal, 8).padding(.vertical, 6)
        }
        .menuIndicator(.hidden)
        .fixedSize()
      }
      if let countSummary {
        Text(countSummary).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
      }
    }
    .buttonStyle(.plain)
    .padding(4)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
  }

  private func button(for action: TextAction, highlighted: Bool) -> some View {
    Button { onRun(action) } label: {
      Label(action.name, systemImage: action.icon)
        .labelStyle(.titleAndIcon)
        .font(.callout.weight(.medium))
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear, in: Capsule())
    }
    .help(action.name)
  }
}

/// Library editor: enable/disable, pin, reorder, edit, import/export.
struct ActionLibraryView: View {
  @Bindable var model: SelectaModel
  @State private var editing: TextAction?
  @State private var importing = false
  @State private var importError: String?

  var body: some View {
    List {
      ForEach($model.actions) { $action in
        HStack {
          Image(systemName: action.icon).frame(width: 22)
          VStack(alignment: .leading) {
            Text(action.name)
            Text(subtitle(action)).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button { action.isPinned.toggle() } label: {
            Image(systemName: action.isPinned ? "pin.fill" : "pin")
          }
          .buttonStyle(.borderless)
          Toggle("", isOn: $action.isEnabled).labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = action }
        .contextMenu {
          Button("Edit") { editing = action }
          if action.kind != .builtIn, let data = try? ActionFile.export(action) {
            ShareLink(
              item: ExportedAction(data: data, name: action.name),
              preview: SharePreview(action.name))
          }
          Button("Delete", role: .destructive) { model.delete(action) }
        }
        .opacity(PlatformCapabilities.current.supports(action.kind) ? 1 : 0.45)
      }
      .onMove { model.actions.move(fromOffsets: $0, toOffset: $1) }
    }
    .toolbar {
      Button { editing = TextAction(name: "", icon: "sparkles", kind: .aiPrompt, outputMode: .showResult) } label: {
        Label("New Action", systemImage: "plus")
      }
      Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
    }
    .sheet(item: $editing) { action in
      ActionEditorView(action: action) { model.upsert($0) }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.selectaAction, .json]) { result in
      do { try model.importAction(from: try result.get()) } catch { importError = "\(error)" }
    }
    .alert("Import failed", isPresented: .constant(importError != nil)) {
      Button("OK") { importError = nil }
    } message: {
      Text(importError ?? "")
    }
  }

  private func subtitle(_ action: TextAction) -> String {
    if !PlatformCapabilities.current.supports(action.kind) { return "Not available on this device" }
    return [action.kind.rawValue, action.group].compactMap { $0 }.joined(separator: " · ")
  }
}

struct ActionEditorView: View {
  @State var action: TextAction
  let onSave: (TextAction) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $action.name)
        TextField("SF Symbol", text: $action.icon)
        if action.kind != .builtIn {
          Picker("Type", selection: $action.kind) {
            ForEach(ActionKind.allCases.filter { $0 != .builtIn && PlatformCapabilities.current.supports($0) }, id: \.self) {
              Text($0.rawValue).tag($0)
            }
          }
          Section(templateTitle) {
            TextEditor(text: $action.template).font(.body.monospaced()).frame(minHeight: 120)
            Text(templateHelp).font(.caption).foregroundStyle(.secondary)
          }
        }
        Picker("Result", selection: $action.outputMode) {
          ForEach(OutputMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        TextField(
          "Suggest when selection matches (regex)",
          text: Binding(get: { action.triggerPattern ?? "" }, set: { action.triggerPattern = $0.isEmpty ? nil : $0 }))
        TextField(
          "Group", text: Binding(get: { action.group ?? "" }, set: { action.group = $0.isEmpty ? nil : $0 }))
      }
      .navigationTitle(action.name.isEmpty ? "New Action" : action.name)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(action)
            dismiss()
          }
          .disabled(action.name.isEmpty)
        }
      }
    }
  }

  private var templateTitle: String {
    switch action.kind {
    case .aiPrompt: "Instruction"
    case .url: "URL template"
    case .javaScript: "JavaScript (receives `text`, returns a value)"
    case .shell: "Shell command (text on stdin and $SELECTA_TEXT)"
    case .appleScript: "AppleScript (on run {input})"
    case .shortcut: "Shortcut name"
    case .builtIn: ""
    }
  }

  private var templateHelp: String {
    "Placeholders: {{text}}, {{url_encoded_text}}, {{trimmed_text}}, {{json_text}}, {{app}}"
  }
}

extension UTType {
  static let selectaAction = UTType(exportedAs: "com.example.selecta.action", conformingTo: .json)
}

struct ExportedAction: Transferable {
  let data: Data
  let name: String
  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .selectaAction) { $0.data }
      .suggestedFileName { "\($0.name).selecta" }
  }
}

/// AI and privacy settings.
struct AISettingsView: View {
  @Bindable var model: SelectaModel
  @State private var apiKey = ""

  var body: some View {
    Form {
      Picker("AI source", selection: $model.ai.provider) {
        ForEach(AISettings.Provider.allCases) { Text($0.label).tag($0) }
      }
      if model.ai.provider != .none, model.ai.provider != .appleIntelligence {
        TextField("Model ID", text: $model.ai.model)
        TextField("Base URL", text: $model.ai.baseURL, prompt: Text(model.ai.provider.defaultBaseURL))
      }
      if model.ai.provider.needsKey {
        SecureField("API key", text: $apiKey)
          .onSubmit { Keychain.set(apiKey, account: model.ai.provider.rawValue) }
        Button("Save key") { Keychain.set(apiKey, account: model.ai.provider.rawValue) }
        Toggle("Allow online actions (sends selected text to this provider)", isOn: $model.ai.allowOnlineActions)
      }
      TextField("Translate into", text: $model.ai.translationTarget)
      TextField("Search URL", text: $model.ai.searchURLTemplate)
    }
    .onChange(of: model.ai.provider) { apiKey = Keychain.get(account: model.ai.provider.rawValue) ?? "" }
    .onAppear { apiKey = Keychain.get(account: model.ai.provider.rawValue) ?? "" }
  }
}
