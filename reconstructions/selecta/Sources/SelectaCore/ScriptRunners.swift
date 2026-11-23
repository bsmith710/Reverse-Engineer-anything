import Foundation

#if os(macOS) || os(Linux)
  /// Runs a shell command with `/bin/sh -c` (zsh on macOS). The selection is written to stdin and
  /// exported as `SELECTA_TEXT`, so commands never need the text spliced into their source.
  public struct ShellRunner: ScriptRunner {
    public var shellPath: String

    public init(shellPath: String? = nil) {
      #if os(macOS)
        self.shellPath = shellPath ?? "/bin/zsh"
      #else
        self.shellPath = shellPath ?? "/bin/sh"
      #endif
    }

    public func run(script: String, input: String, timeout: Double) async throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: shellPath)
      process.arguments = ["-c", script]
      var env = ProcessInfo.processInfo.environment
      env["SELECTA_TEXT"] = input
      process.environment = env
      let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
      process.standardInput = stdin
      process.standardOutput = stdout
      process.standardError = stderr

      // Read output concurrently so a large result cannot deadlock on a full pipe.
      let outTask = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
      let errTask = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }

      try process.run()
      let writer = stdin.fileHandleForWriting
      try? writer.write(contentsOf: Data(input.utf8))
      try? writer.close()

      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning {
        if Date() >= deadline {
          // Do not wait for the pipe readers: a child of the shell (e.g. `sleep`) can keep the pipe
          // open after the shell exits. The readers finish on their own when that child exits.
          process.terminate()
          throw SelectaError.scriptTimedOut(seconds: timeout)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      let out = String(decoding: await outTask.value, as: UTF8.self)
      let err = String(decoding: await errTask.value, as: UTF8.self)
      guard process.terminationStatus == 0 else {
        let message = err.isEmpty ? "exit status \(process.terminationStatus)" : err
        throw SelectaError.scriptFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return out.hasSuffix("\n") ? String(out.dropLast()) : out
    }
  }
#endif

#if canImport(JavaScriptCore)
  import JavaScriptCore

  /// Runs a JavaScript function body with JavaScriptCore. The body receives `text` and returns a
  /// string, number, boolean, array, or object (non-strings are returned as JSON).
  ///
  /// Limitation: JavaScriptCore has no public way to interrupt a running script. A timeout returns an
  /// error to the caller, but a runaway loop keeps its worker thread busy until the process exits.
  /// The macOS app can move this into an XPC helper that is killed on timeout (see ANALYSIS.md).
  public struct JavaScriptRunner: ScriptRunner {
    public init() {}

    public func run(script: String, input: String, timeout: Double) async throws -> String {
      try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
          try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
              continuation.resume(with: Result { try Self.evaluate(script: script, input: input) })
            }
          }
        }
        group.addTask {
          try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
          throw SelectaError.scriptTimedOut(seconds: timeout)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw SelectaError.scriptFailed("no result") }
        return first
      }
    }

    static func evaluate(script: String, input: String) throws -> String {
      guard let context = JSContext() else { throw SelectaError.scriptFailed("JavaScriptCore unavailable") }
      var thrown: String?
      context.exceptionHandler = { _, exception in thrown = exception?.toString() }
      context.setObject(input, forKeyedSubscript: "text" as NSString)
      let wrapped = "(function(text){\n\(script)\n})(text)"
      let value = context.evaluateScript(wrapped)
      if let thrown { throw SelectaError.scriptFailed(thrown) }
      guard let value, !value.isUndefined, !value.isNull else {
        throw SelectaError.scriptFailed("The script did not return a value.")
      }
      if value.isString { return value.toString() }
      if value.isNumber || value.isBoolean { return value.toString() }
      guard let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value, NSNull(), 2]),
        json.isString
      else { throw SelectaError.scriptFailed("The returned value could not be converted to JSON.") }
      return json.toString()
    }
  }
#endif
