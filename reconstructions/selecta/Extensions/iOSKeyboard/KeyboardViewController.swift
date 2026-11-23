import SelectaCore
import SwiftUI
import UIKit

/// An "action keyboard": the closest iOS gets to system-wide replace. It reads the host field's
/// selection through `textDocumentProxy.selectedText` and replaces it with `insertText`.
/// Network (online AI) needs the user to grant Full Access; local actions work without it.
final class KeyboardViewController: UIInputViewController {
  private var host: UIHostingController<KeyboardActionBar>?

  override func viewDidLoad() {
    super.viewDidLoad()
    let bar = UIHostingController(rootView: makeBar())
    bar.view.backgroundColor = .clear
    addChild(bar)
    bar.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(bar.view)
    NSLayoutConstraint.activate([
      bar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bar.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bar.view.topAnchor.constraint(equalTo: view.topAnchor),
      bar.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      bar.view.heightAnchor.constraint(equalToConstant: 216),
    ])
    bar.didMove(toParent: self)
    host = bar
  }

  override func textDidChange(_ textInput: UITextInput?) {
    host?.rootView = makeBar()
  }

  override func selectionDidChange(_ textInput: UITextInput?) {
    host?.rootView = makeBar()
  }

  private func makeBar() -> KeyboardActionBar {
    KeyboardActionBar(
      model: SelectaModel(),
      selectedText: textDocumentProxy.selectedText ?? "",
      hasFullAccess: hasFullAccess,
      replace: { [weak self] text in self?.textDocumentProxy.insertText(text) },
      nextKeyboard: { [weak self] in self?.advanceToNextInputMode() })
  }
}

struct KeyboardActionBar: View {
  let model: SelectaModel
  let selectedText: String
  let hasFullAccess: Bool
  let replace: (String) -> Void
  let nextKeyboard: () -> Void
  @State private var status: String?

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Button(action: nextKeyboard) { Image(systemName: "globe") }
        Text(selectedText.isEmpty ? "Select text in the field above" : TextTransforms.countSummary(selectedText))
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        if let status { Text(status).font(.caption).lineLimit(1) }
      }
      .padding(.horizontal)
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104))], spacing: 8) {
          ForEach(actions) { action in
            Button { run(action) } label: {
              Label(action.name, systemImage: action.icon)
                .font(.footnote).frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal)
      }
    }
    .padding(.top, 8)
  }

  private var actions: [TextAction] {
    model.ranked(for: SelectionContext(text: selectedText)).ordered.filter {
      $0.builtIn != .askAI && $0.builtIn != .paste && $0.builtIn != .pastePlain && $0.kind != .shortcut
    }
  }

  private func run(_ action: TextAction) {
    guard !selectedText.isEmpty else { return }
    let needsNetwork = action.kind == .aiPrompt || action.builtIn?.usesAI == true || action.kind == .url
    if needsNetwork, !hasFullAccess {
      status = "Needs Full Access"
      return
    }
    status = "Running…"
    Task { @MainActor in
      do {
        switch try await model.run(action, on: SelectionContext(text: selectedText)) {
        case .text(let s, .replace): replace(s); status = nil
        case .text(let s, _): UIPasteboard.general.string = s; status = "Copied"
        case .host(.copy(let s)): UIPasteboard.general.string = s; status = "Copied"
        case .host(.cut(let s)): UIPasteboard.general.string = s; replace(""); status = nil
        case .host: status = "Not available in keyboard"
        }
      } catch {
        status = "\(error)"
      }
    }
  }
}
