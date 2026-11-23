import SelectaCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Action extension: appears in the share sheet for selected text in any app. Returns the result to
/// the host (apps that accept returned text replace the selection) and copies it to the clipboard.
final class ActionViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    Task { @MainActor in
      let text = await loadSharedText() ?? ""
      let host = UIHostingController(
        rootView: ExtensionActionView(model: SelectaModel(), text: text) { [weak self] output in
          self?.finish(returning: output)
        })
      addChild(host)
      host.view.frame = view.bounds
      host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.addSubview(host.view)
      host.didMove(toParent: self)
    }
  }

  private func loadSharedText() async -> String? {
    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    for provider in items.flatMap({ $0.attachments ?? [] }) {
      for type in [UTType.plainText, .url] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
        if let value = try? await provider.loadItem(forTypeIdentifier: type.identifier) {
          if let s = value as? String { return s }
          if let u = value as? URL { return u.absoluteString }
          if let d = value as? Data { return String(data: d, encoding: .utf8) }
        }
      }
    }
    return items.compactMap { $0.attributedContentText?.string }.first
  }

  private func finish(returning output: String?) {
    guard let output else {
      extensionContext?.completeRequest(returningItems: nil)
      return
    }
    UIPasteboard.general.string = output
    let item = NSExtensionItem()
    item.attachments = [NSItemProvider(item: output as NSString, typeIdentifier: UTType.plainText.identifier)]
    extensionContext?.completeRequest(returningItems: [item])
  }
}

struct ExtensionActionView: View {
  let model: SelectaModel
  let text: String
  let done: (String?) -> Void
  @State private var output: String?
  @State private var running: String?
  @State private var instruction = ""
  @State private var asking: TextAction?

  var body: some View {
    NavigationStack {
      List {
        Section("Selection") {
          Text(text).lineLimit(4).foregroundStyle(.secondary)
          Text(TextTransforms.countSummary(text)).font(.caption)
        }
        if let output {
          Section("Result") {
            Text(output).textSelection(.enabled)
            Button("Done — return and copy result") { done(output) }.bold()
          }
        }
        if let asking {
          Section("Ask AI") {
            TextField("Instruction", text: $instruction).onSubmit { run(asking, instruction: instruction) }
          }
        }
        Section("Actions") {
          ForEach(model.ranked(for: SelectionContext(text: text, isEditable: false)).ordered) { action in
            Button { action.builtIn == .askAI ? (asking = action) : run(action) } label: {
              HStack {
                Label(action.name, systemImage: action.icon)
                Spacer()
                if running == action.name { ProgressView() }
              }
            }
          }
        }
      }
      .navigationTitle("Selecta")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Cancel") { done(nil) } }
    }
  }

  private func run(_ action: TextAction, instruction: String? = nil) {
    running = action.name
    Task { @MainActor in
      defer { running = nil }
      do {
        switch try await model.run(action, on: SelectionContext(text: text, isEditable: false), instruction: instruction) {
        case .text(let s, _): output = s
        case .host(.copy(let s)), .host(.cut(let s)): done(s)
        case .host(.openURL(let url)): output = url.absoluteString  // extensions cannot open arbitrary URLs
        case .host: output = text
        }
      } catch {
        output = "\(error)"
      }
    }
  }
}
