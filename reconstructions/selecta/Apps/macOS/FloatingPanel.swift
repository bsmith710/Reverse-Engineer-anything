import AppKit
import SelectaCore
import SwiftUI

/// A borderless, non-activating panel so showing it never steals focus from the source app.
final class FloatingPanel: NSPanel {
  init() {
    super.init(
      contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
  }

  override var canBecomeKey: Bool { true }  // needed for text fields in the result/ask views
  override var canBecomeMain: Bool { false }
}

/// Shows the action bar near a selection and the result card after an action runs.
@MainActor
final class FloatingPanelController {
  private let panel = FloatingPanel()
  private let model: SelectaModel
  private var selection: ObservedSelection?

  init(model: SelectaModel) {
    self.model = model
  }

  var isVisible: Bool { panel.isVisible }

  func show(for selection: ObservedSelection) {
    self.selection = selection
    let ranked = model.ranked(for: selection.context)
    let summary = TextTransforms.countSummary(selection.context.text)
    setContent(ActionBarView(ranked: ranked, onRun: { [weak self] in self?.run($0) }, countSummary: summary))
    place(near: selection.bounds)
    panel.orderFrontRegardless()
  }

  func hide() {
    panel.orderOut(nil)
  }

  private func run(_ action: TextAction, instruction: String? = nil) {
    guard let selection else { return }
    if action.builtIn == .askAI, instruction == nil {
      setContent(AskView { [weak self] prompt in self?.run(action, instruction: prompt) })
      panel.makeKey()
      return
    }
    setContent(ResultCard(title: action.name, text: nil, error: nil, onCopy: {}, onReplace: nil, onClose: { [weak self] in self?.hide() }))
    Task {
      do {
        let outcome = try await model.run(action, on: selection.context, instruction: instruction)
        switch outcome {
        case .host(let command):
          hide()
          await HostBridge.perform(command, selection: selection)
        case .text(let text, .replace) where selection.context.isEditable:
          hide()
          await HostBridge.replace(selection, with: text)
        case .text(let text, .copy):
          HostBridge.copy(text)
          hide()
        case .text(_, .none):
          hide()
        case .text(let text, _):
          presentResult(action.name, text)
        }
      } catch {
        setContent(ResultCard(title: action.name, text: nil, error: "\(error)", onCopy: {}, onReplace: nil, onClose: { [weak self] in self?.hide() }))
      }
    }
  }

  private func presentResult(_ title: String, _ text: String) {
    guard let selection else { return }
    setContent(
      ResultCard(
        title: title, text: text, error: nil,
        onCopy: { [weak self] in
          HostBridge.copy(text)
          self?.hide()
        },
        onReplace: selection.context.isEditable
          ? { [weak self] in
            self?.hide()
            Task { await HostBridge.replace(selection, with: text) }
          } : nil,
        onClose: { [weak self] in self?.hide() }))
    panel.makeKey()
  }

  private func setContent<V: View>(_ view: V) {
    let host = NSHostingView(rootView: view.padding(10).fixedSize())
    panel.contentView = host
    let size = host.fittingSize
    var frame = panel.frame
    frame.origin.y += frame.height - size.height  // grow downward from the top edge
    frame.size = size
    panel.setFrame(frame, display: true)
  }

  /// Above the selection when there is room, otherwise below; falls back to the mouse position.
  private func place(near bounds: CGRect?) {
    let anchor = bounds ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
    let size = panel.frame.size
    let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero
    var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 6)
    if origin.y + size.height > visible.maxY { origin.y = anchor.minY - size.height - 6 }
    origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
    origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
    panel.setFrameOrigin(origin)
  }
}

struct AskView: View {
  let onSubmit: (String) -> Void
  @State private var prompt = ""

  var body: some View {
    HStack {
      Image(systemName: "sparkles")
      TextField("Ask about the selection…", text: $prompt)
        .textFieldStyle(.plain)
        .frame(width: 320)
        .onSubmit { if !prompt.isEmpty { onSubmit(prompt) } }
    }
    .padding(10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}

struct ResultCard: View {
  let title: String
  let text: String?
  let error: String?
  let onCopy: () -> Void
  let onReplace: (() -> Void)?
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button(action: onClose) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
      }
      if let error {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      } else if let text {
        ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          .frame(maxHeight: 260)
        HStack {
          Button("Copy", action: onCopy).keyboardShortcut("c")
          if let onReplace { Button("Replace", action: onReplace).keyboardShortcut(.return) }
        }
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .frame(width: 380)
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
  }
}
