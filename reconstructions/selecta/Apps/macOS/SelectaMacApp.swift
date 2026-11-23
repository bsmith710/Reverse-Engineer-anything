import AppKit
import Carbon.HIToolbox
import SelectaCore
import SwiftUI

/// Menu-bar app (LSUIElement). Not sandboxed: system-wide Accessibility reading, synthesized key
/// events, shell and AppleScript actions are incompatible with the App Sandbox. Distribute with a
/// Developer ID signature and notarization.
@main
struct SelectaMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    MenuBarExtra("Selecta", systemImage: "text.cursor") {
      MenuContent(delegate: delegate)
    }
    Settings {
      MacSettingsView(model: delegate.model, delegate: delegate)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  let model = SelectaModel()
  let monitor = SelectionMonitor()
  lazy var panel = FloatingPanelController(model: model)
  private var hotKey: GlobalHotKey?
  @Published var isPaused = false
  @Published var isTrusted = SelectionMonitor.isTrusted

  func applicationDidFinishLaunching(_ notification: Notification) {
    if !SelectionMonitor.isTrusted { SelectionMonitor.requestTrust() }
    monitor.onSelection = { [weak self] selection in
      guard let self, !self.isPaused else { return }
      self.panel.show(for: selection)
    }
    monitor.onDismiss = { [weak self] in self?.panel.hide() }
    monitor.start()
    // ⌥⌘Space shows the bar for the current selection, including in apps where auto-trigger misfires.
    hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in
      Task { @MainActor in
        guard let self, let selection = await self.monitor.readNow() else { return }
        self.panel.show(for: selection)
      }
    }
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.isTrusted = SelectionMonitor.isTrusted }
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.pathExtension == "selecta" { try? model.importAction(from: url) }
  }
}

struct MenuContent: View {
  @ObservedObject var delegate: AppDelegate

  var body: some View {
    if !delegate.isTrusted {
      Button("Grant Accessibility Access…") { SelectionMonitor.requestTrust() }
      Divider()
    }
    Toggle("Pause Selecta", isOn: $delegate.isPaused)
    Button("Show Actions for Selection  ⌥⌘Space") {
      Task {
        if let s = await delegate.monitor.readNow() { delegate.panel.show(for: s) }
      }
    }
    Divider()
    SettingsLink { Text("Settings…") }.keyboardShortcut(",")
    Button("Quit Selecta") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}

struct MacSettingsView: View {
  @Bindable var model: SelectaModel
  @ObservedObject var delegate: AppDelegate
  @AppStorage("clipboardFallback") private var clipboardFallback = false
  @AppStorage("excludedApps") private var excludedApps = ""

  var body: some View {
    TabView {
      NavigationStack { ActionLibraryView(model: model) }
        .tabItem { Label("Actions", systemImage: "square.grid.2x2") }
      AISettingsView(model: model)
        .tabItem { Label("AI", systemImage: "sparkles") }
      Form {
        Toggle("Use ⌘C fallback when an app hides its selection", isOn: $clipboardFallback)
        Text("The fallback briefly uses the clipboard and restores it afterwards.").font(.caption)
        TextField("Exclude apps (bundle IDs, comma-separated)", text: $excludedApps)
      }
      .tabItem { Label("Behavior", systemImage: "gearshape") }
    }
    .frame(width: 560, height: 480)
    .onChange(of: clipboardFallback, initial: true) { delegate.monitor.useClipboardFallback = clipboardFallback }
    .onChange(of: excludedApps, initial: true) {
      delegate.monitor.excludedBundleIDs = Set(
        excludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
  }
}

/// Minimal Carbon global hotkey (works without Accessibility or Input Monitoring permission).
final class GlobalHotKey {
  private var ref: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let action: () -> Void

  init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
    self.action = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
        return noErr
      }, 1, &spec, selfPtr, &handler)
    let id = EventHotKeyID(signature: OSType(0x534C_4354), id: 1)  // 'SLCT'
    RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
  }

  deinit {
    if let ref { UnregisterEventHotKey(ref) }
    if let handler { RemoveEventHandler(handler) }
  }
}
