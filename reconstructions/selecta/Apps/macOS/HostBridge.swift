import AppKit
import ApplicationServices
import SelectaCore

/// Executes action outcomes against the source app on macOS.
@MainActor
enum HostBridge {
  /// Replaces the selection: AX set first (no clipboard side effects), then paste fallback.
  static func replace(_ selection: ObservedSelection, with text: String) async {
    NSRunningApplication(processIdentifier: selection.pid)?.activate()
    if let element = selection.element, selection.context.isEditable,
      AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    {
      return
    }
    await paste(text, into: selection.pid)
  }

  /// Pastes `text` with ⌘V and restores the user's clipboard afterwards.
  static func paste(_ text: String, into pid: pid_t) async {
    NSRunningApplication(processIdentifier: pid)?.activate()
    let pasteboard = NSPasteboard.general
    let snapshot = PasteboardSnapshot(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    try? await Task.sleep(nanoseconds: 50_000_000)
    KeySender.send(key: 9, flags: .maskCommand)  // kVK_ANSI_V
    // Give the target app time to read the pasteboard before restoring it.
    try? await Task.sleep(nanoseconds: 400_000_000)
    snapshot.restore(to: pasteboard)
  }

  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  static func perform(_ command: HostCommand, selection: ObservedSelection) async {
    switch command {
    case .copy(let text):
      copy(text)
    case .cut(let text):
      copy(text)
      NSRunningApplication(processIdentifier: selection.pid)?.activate()
      KeySender.send(key: 51)  // kVK_Delete
    case .paste(let plain):
      NSRunningApplication(processIdentifier: selection.pid)?.activate()
      if plain, let string = NSPasteboard.general.string(forType: .string) {
        await paste(string, into: selection.pid)
      } else {
        KeySender.send(key: 9, flags: .maskCommand)
      }
    case .openURL(let url):
      NSWorkspace.shared.open(url)
    case .runShortcut(let name, let input):
      await ShortcutsCLI.run(name: name, input: input)
    }
  }
}

/// Runs a Shortcuts shortcut through `/usr/bin/shortcuts`, passing the selection as input.
enum ShortcutsCLI {
  static func run(name: String, input: String) async {
    await Task.detached {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("selecta-\(UUID().uuidString).txt")
      try? Data(input.utf8).write(to: file)
      defer { try? FileManager.default.removeItem(at: file) }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
      process.arguments = ["run", name, "--input-path", file.path]
      try? process.run()
      process.waitUntilExit()  // off the main actor
    }.value
  }
}

/// Runs AppleScript with the selection passed to `on run {input}`; plain scripts also work.
struct AppleScriptRunner: ScriptRunner {
  func run(script: String, input: String, timeout: Double) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        // `osascript` runs out of process, so a timeout can terminate it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, input]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
          continuation.resume(throwing: SelectaError.scriptFailed("\(error)"))
          return
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationReason == .uncaughtSignal {
          continuation.resume(throwing: SelectaError.scriptTimedOut(seconds: timeout))
        } else if process.terminationStatus != 0 {
          continuation.resume(throwing: SelectaError.scriptFailed(error.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else {
          continuation.resume(returning: output.trimmingCharacters(in: .newlines))
        }
      }
    }
  }
}
