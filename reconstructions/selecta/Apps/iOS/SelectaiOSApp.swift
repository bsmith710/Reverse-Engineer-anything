import SelectaCore
import SwiftUI
import UIKit

/// iOS cannot observe selections in other apps. Selecta reaches text on iOS through:
/// 1. the Action extension ("Selecta" in the share sheet of any app that shares selected text),
/// 2. the Selecta keyboard (reads `selectedText` and replaces it in place),
/// 3. Shortcuts / Siri / Action button via App Intents, and
/// 4. this app's own editor, whose native edit menu carries the action library.
@main
struct SelectaiOSApp: App {
  @State private var model = SelectaModel()

  var body: some Scene {
    WindowGroup {
      TabView {
        NavigationStack { ScratchpadView(model: model).navigationTitle("Scratchpad") }
          .tabItem { Label("Scratchpad", systemImage: "square.and.pencil") }
        NavigationStack { ActionLibraryView(model: model).navigationTitle("Actions") }
          .tabItem { Label("Actions", systemImage: "square.grid.2x2") }
        NavigationStack { AISettingsView(model: model).navigationTitle("AI") }
          .tabItem { Label("AI", systemImage: "sparkles") }
        NavigationStack { SetupGuideView().navigationTitle("Use Everywhere") }
          .tabItem { Label("Setup", systemImage: "questionmark.circle") }
      }
      .onOpenURL { url in if url.pathExtension == "selecta" { try? model.importAction(from: url) } }
    }
  }
}

struct ScratchpadView: View {
  @Bindable var model: SelectaModel
  @State private var text = "Select some text and pick an action from the edit menu."
  @State private var result: ResultSheet?

  var body: some View {
    ActionTextView(text: $text, model: model) { action, range, selected in
      Task { await run(action, range: range, selected: selected) }
    }
    .padding(.horizontal)
    .sheet(item: $result) { sheet in
      NavigationStack {
        ScrollView { Text(sheet.text).textSelection(.enabled).padding() }
          .navigationTitle(sheet.title)
          .toolbar {
            Button("Copy") { UIPasteboard.general.string = sheet.text }
          }
      }
      .presentationDetents([.medium, .large])
    }
  }

  @MainActor
  private func run(_ action: TextAction, range: NSRange, selected: String) async {
    do {
      let outcome = try await model.run(action, on: SelectionContext(text: selected, sourceAppName: "Selecta"))
      switch outcome {
      case .text(let output, .replace):
        if let r = Range(range, in: text) { text.replaceSubrange(r, with: output) }
      case .text(let output, .copy): UIPasteboard.general.string = output
      case .text(_, .none): break
      case .text(let output, _): result = ResultSheet(title: action.name, text: output)
      case .host(let command): await IOSHost.perform(command)
      }
    } catch {
      result = ResultSheet(title: action.name, text: "\(error)")
    }
  }
}

struct ResultSheet: Identifiable {
  let id = UUID()
  let title: String
  let text: String
}

/// UITextView whose system edit menu (the iPhone callout bar) gains a Selecta submenu.
struct ActionTextView: UIViewRepresentable {
  @Binding var text: String
  let model: SelectaModel
  let onAction: (TextAction, NSRange, String) -> Void

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.font = .preferredFont(forTextStyle: .body)
    view.delegate = context.coordinator
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    if view.text != text { view.text = text }
    context.coordinator.parent = self
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ActionTextView
    init(parent: ActionTextView) { self.parent = parent }

    func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }

    func textView(
      _ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      guard range.length > 0, let swiftRange = Range(range, in: textView.text) else { return nil }
      let selected = String(textView.text[swiftRange])
      let ranked = parent.model.ranked(for: SelectionContext(text: selected))
      let make: (TextAction) -> UIAction = { action in
        UIAction(title: action.name, image: UIImage(systemName: action.icon)) { [weak self] _ in
          self?.parent.onAction(action, range, selected)
        }
      }
      // Suggestions go inline in the callout bar; the full library sits in a submenu.
      let suggested = ranked.suggestions.map(make)
      let library = UIMenu(title: "Selecta", image: UIImage(systemName: "text.cursor"), children: (ranked.pinned + ranked.others).map(make))
      return UIMenu(children: suggested + [library] + suggestedActions)
    }
  }
}

enum IOSHost {
  @MainActor
  static func perform(_ command: HostCommand) async {
    switch command {
    case .copy(let text), .cut(let text): UIPasteboard.general.string = text
    case .paste: break  // the system edit menu already offers Paste in the app's own editor
    case .openURL(let url): await UIApplication.shared.open(url)
    case .runShortcut(let name, let input):
      UIPasteboard.general.string = input
      var components = URLComponents(string: "shortcuts://run-shortcut")!
      components.queryItems = [.init(name: "name", value: name), .init(name: "input", value: "clipboard")]
      if let url = components.url { await UIApplication.shared.open(url) }
    }
  }
}

struct SetupGuideView: View {
  var body: some View {
    List {
      Section("Share sheet (any app)") {
        Text("Select text → Share → Selecta. Add it to your favorites in Edit Actions to keep it near the top.")
      }
      Section("Selecta keyboard (replace in place)") {
        Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → Selecta. Allow Full Access only if you use online AI actions.")
        Text("Select text, switch to the Selecta keyboard with the globe key, and tap an action.")
      }
      Section("Shortcuts, Siri, Action button, Back Tap") {
        Text("Use the “Run Selecta Action” shortcut action. It accepts text or uses the clipboard.")
      }
    }
  }
}
