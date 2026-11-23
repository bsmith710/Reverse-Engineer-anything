import Foundation
import Testing

@testable import SelectaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct TemplateTests {
  let ctx = SelectionContext(text: "it's a \"test\" & more", sourceAppName: "Notes")

  @Test func resolvesKnownTokensAndKeepsUnknown() {
    let r = TemplateResolver()
    #expect(r.resolve("q={{url_encoded_text}}", context: ctx) == "q=it%27s%20a%20%22test%22%20%26%20more")
    #expect(r.resolve("{{shell_quoted_text}}", context: ctx) == #"'it'\''s a "test" & more'"#)
    #expect(r.resolve("{{applescript_text}}", context: ctx) == #""it's a \"test\" & more""#)
    #expect(r.resolve("from {{app}}: {{nope}}", context: ctx) == "from Notes: {{nope}}")
    #expect(r.resolve("unterminated {{text", context: ctx) == "unterminated {{text")
  }

  @Test func jsonLiteralEscapes() {
    #expect(TemplateResolver.jsonLiteral("a\"b\n") == #""a\"b\n""#)
  }
}

@Suite struct TransformTests {
  @Test func titleCaseKeepsMinorWordsAndAcronyms() {
    #expect(TextTransforms.titleCase("the lord of the rings on iPhone") == "The Lord of the Rings on iPhone")
    #expect(TextTransforms.titleCase("NASA and the moon") == "NASA and the Moon")
  }

  @Test func sentenceCase() {
    #expect(TextTransforms.sentenceCase("HELLO there. how ARE you? fine") == "Hello there. How are you? Fine")
  }

  @Test func countsGraphemesAndWords() {
    #expect(TextTransforms.countSummary("Project deadline moved to Friday.") == "33 chars • 5 words")
    #expect(TextTransforms.characterCount("👍🏽ok") == 3)
    #expect(TextTransforms.countSummary("a") == "1 char • 1 word")
  }

  @Test func linesAndEncoding() {
    #expect(TextTransforms.sortLines("b\na\nC") == "a\nb\nC")
    #expect(TextTransforms.removeDuplicateLines("x\ny\nx") == "x\ny")
    #expect(TextTransforms.base64Decode("aGVsbG8gd29ybGQ") == "hello world")
    #expect(TextTransforms.prettyJSON(#"{"b":1,"a":[true]}"#)?.contains("\"a\" : [") == true)
    #expect(TextTransforms.prettyJSON("{nope") == nil)
  }
}

@Suite struct ConversionTests {
  @Test func colors() throws {
    let c = try #require(ColorConverter.parse("#ff8000"))
    #expect(ColorConverter.hex(c) == "#FF8000")
    #expect(ColorConverter.rgb(c) == "rgb(255, 128, 0)")
    #expect(ColorConverter.hsl(c) == "hsl(30, 100%, 50%)")
    #expect(ColorConverter.hex(try #require(ColorConverter.parse("#0f08"))) == "#00FF0088")
    #expect(ColorConverter.hex(try #require(ColorConverter.parse("rgb(0, 0, 255)"))) == "#0000FF")
    #expect(ColorConverter.hex(try #require(ColorConverter.parse("hsl(120, 100%, 25%)"))) == "#008000")
    #expect(ColorConverter.parse("#ggg") == nil)
    #expect(ColorConverter.parse("hello") == nil)
  }

  @Test func units() {
    #expect(UnitConverter.summary("70°F") == "21.11°C")
    #expect(UnitConverter.summary("100 c") == "212°F")
    #expect(UnitConverter.summary("5 km") == "3.11 mi")
    #expect(UnitConverter.summary("16px") == "12 pt\n1 rem")
    #expect(UnitConverter.summary("1,500 MB") == "1430.5 MiB")
    #expect(UnitConverter.summary("2 lbs") == "0.907 kg")
    #expect(UnitConverter.summary("1 mm") == "0.0394 in")
    #expect(UnitConverter.summary("12 parsecs") == nil)
    #expect(UnitConverter.summary("just words") == nil)
  }
}

@Suite struct ClassifierTests {
  @Test func detectsTraits() {
    #expect(SelectionClassifier.traits(of: "https://example.com/a?b=1").contains(.url))
    #expect(SelectionClassifier.traits(of: "example.com").contains(.url))
    #expect(SelectionClassifier.traits(of: "jane@example.com").contains(.email))
    #expect(SelectionClassifier.traits(of: "#1e90ff").contains(.color))
    #expect(SelectionClassifier.traits(of: "12.5 kg").contains(.measurement))
    #expect(SelectionClassifier.traits(of: #"{"a": 1}"#).contains(.json))
    #expect(SelectionClassifier.traits(of: "+1 (555) 010-2000").contains(.phone))
    #expect(SelectionClassifier.traits(of: "1600 Pennsylvania Avenue NW, Washington").contains(.address))
    let plain = SelectionClassifier.traits(of: "deadline moved to Friday")
    #expect(plain.isDisjoint(with: [.url, .email, .color, .measurement, .json, .phone, .address, .base64]))
  }

  @Test func rankingPutsSuggestionsThenPinned() {
    var custom = TextAction(
      name: "Ticket", icon: "ticket", kind: .url, template: "https://tracker.example/{{text}}",
      outputMode: .none, triggerPattern: #"^[A-Z]+-\d+$"#)
    custom.isPinned = false
    let actions = ActionStore.defaultActions + [custom]

    let ticket = ActionRanker.rank(actions, for: SelectionContext(text: "OPS-42"))
    #expect(ticket.suggestions.first?.name == "Ticket")

    let url = ActionRanker.rank(actions, for: SelectionContext(text: "https://example.com"))
    #expect(url.suggestions.first?.builtIn == .openLink)
    #expect(url.pinned.map(\.builtIn) == [.copy, .paste, .webSearch, .askAI])

    let readOnly = ActionRanker.rank(actions, for: SelectionContext(text: "x", isEditable: false))
    #expect(!readOnly.ordered.contains { $0.builtIn == .paste || $0.builtIn == .cut })
  }
}

struct FakeTransport: HTTPTransport {
  let status: Int
  let body: String
  let captured: @Sendable (URLRequest) -> Void
  func send(_ request: URLRequest) async throws -> (Data, Int) {
    captured(request)
    return (Data(body.utf8), status)
  }
}

final class Box<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}

@Suite struct AITests {
  @Test func openAICompatibleRoundTrip() async throws {
    let seen = Box<URLRequest?>(nil)
    let client = OpenAICompatibleClient(
      baseURL: URL(string: "http://localhost:11434/v1")!, model: "local-model", apiKey: nil,
      transport: FakeTransport(status: 200, body: #"{"choices":[{"message":{"content":" Hi. "}}]}"#) {
        seen.value = $0
      })
    #expect(client.isOnDevice)
    let out = try await client.complete(system: "s", prompt: "p")
    #expect(out == "Hi.")
    let req = try #require(seen.value)
    #expect(req.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func anthropicRequestAndErrors() async throws {
    let seen = Box<URLRequest?>(nil)
    let ok = AnthropicClient(
      model: "configured-model", apiKey: "k",
      transport: FakeTransport(status: 200, body: #"{"content":[{"type":"text","text":"Done"}]}"#) { seen.value = $0 })
    #expect(try await ok.complete(system: "s", prompt: "p") == "Done")
    #expect(seen.value?.value(forHTTPHeaderField: "x-api-key") == "k")
    #expect(seen.value?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

    let bad = AnthropicClient(
      model: "m", apiKey: "k", transport: FakeTransport(status: 401, body: "denied") { _ in })
    await #expect(throws: SelectaError.aiRequestFailed(status: 401, body: "denied")) {
      try await bad.complete(system: "s", prompt: "p")
    }
    #expect(throws: SelectaError.aiResponseMalformed) { try AnthropicClient.parse(Data("{}".utf8)) }
  }
}

struct EchoAI: AIClient {
  var isOnDevice: Bool { true }
  func complete(system: String, prompt: String) async throws -> String { "AI<\(prompt)>" }
}

@Suite struct EngineTests {
  @Test func builtInsAndHostCommands() async throws {
    let engine = ActionEngine(capabilities: .linux)
    let ctx = SelectionContext(text: "hello world")
    #expect(try await engine.run(.builtIn(.uppercase), on: ctx) == .text("HELLO WORLD", mode: .replace))
    #expect(try await engine.run(.builtIn(.copy), on: ctx) == .host(.copy("hello world")))
    #expect(
      try await engine.run(.builtIn(.webSearch), on: ctx)
        == .host(.openURL(URL(string: "https://duckduckgo.com/?q=hello%20world")!)))
    #expect(
      try await engine.run(.builtIn(.openLink), on: SelectionContext(text: " example.com "))
        == .host(.openURL(URL(string: "https://example.com")!)))
    await #expect(throws: SelectaError.emptySelection) {
      try await engine.run(.builtIn(.uppercase), on: SelectionContext(text: ""))
    }
    await #expect(throws: SelectaError.aiNotConfigured) {
      try await engine.run(.builtIn(.summarize), on: ctx)
    }
  }

  @Test func aiPromptSeparatesInstructionFromText() async throws {
    let engine = ActionEngine(ai: EchoAI(), capabilities: .linux)
    let action = TextAction(name: "Reply", icon: "x", kind: .aiPrompt, template: "Reply to {{app}}", outputMode: .showResult)
    let out = try await engine.run(action, on: SelectionContext(text: "hi", sourceAppName: "Mail"))
    #expect(out == .text("AI<Instruction: Reply to Mail\n\n<selected_text>\nhi\n</selected_text>>", mode: .showResult))
  }

  @Test func platformGatesUnsupportedKinds() async throws {
    let engine = ActionEngine(capabilities: .iOS)
    let shell = TextAction(name: "s", icon: "x", kind: .shell, template: "cat", outputMode: .replace)
    await #expect(throws: SelectaError.unsupportedOnPlatform(.shell)) {
      try await engine.run(shell, on: SelectionContext(text: "x"))
    }
  }

  #if os(Linux) || os(macOS)
    @Test func shellReceivesTextSafely() async throws {
      let engine = ActionEngine(shell: ShellRunner(), capabilities: .linux, scriptTimeout: 5)
      let payload = "a'; echo INJECTED; '"
      let echo = TextAction(name: "e", icon: "x", kind: .shell, template: "printf %s {{text}}", outputMode: .replace)
      #expect(try await engine.run(echo, on: SelectionContext(text: payload)) == .text(payload, mode: .replace))
      let stdin = TextAction(name: "u", icon: "x", kind: .shell, template: "tr a-z A-Z", outputMode: .replace)
      #expect(try await engine.run(stdin, on: SelectionContext(text: "abc")) == .text("ABC", mode: .replace))
      let env = TextAction(name: "v", icon: "x", kind: .shell, template: "printf %s \"$SELECTA_TEXT\" | wc -c", outputMode: .copy)
      let counted = try await engine.run(env, on: SelectionContext(text: "four"))
      #expect(counted == .text("4", mode: .copy) || counted == .text("       4", mode: .copy))
    }

    @Test func shellFailureAndTimeout() async throws {
      let engine = ActionEngine(shell: ShellRunner(), capabilities: .linux, scriptTimeout: 0.5)
      let fail = TextAction(name: "f", icon: "x", kind: .shell, template: "echo nope >&2; exit 3", outputMode: .replace)
      await #expect(throws: SelectaError.scriptFailed("nope")) {
        try await engine.run(fail, on: SelectionContext(text: "x"))
      }
      let slow = TextAction(name: "t", icon: "x", kind: .shell, template: "sleep 5; echo late", outputMode: .replace)
      let started = Date()
      await #expect(throws: SelectaError.scriptTimedOut(seconds: 0.5)) {
        try await engine.run(slow, on: SelectionContext(text: "x"))
      }
      #expect(Date().timeIntervalSince(started) < 2)
    }
  #endif
}

@Suite struct StoreTests {
  @Test func persistsAndMerges() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ActionStore(directory: dir)
    #expect(store.load() == ActionStore.defaultActions)

    var actions = Array(ActionStore.defaultActions.prefix(3))
    actions[0].isPinned = false
    try store.save(actions)
    let loaded = store.load()
    #expect(loaded.prefix(3).elementsEqual(actions))
    #expect(loaded.count == ActionStore.defaultActions.count)
    #expect(loaded.dropFirst(3).allSatisfy { !$0.isEnabled })
  }

  @Test func stableBuiltInIDs() {
    #expect(BuiltInAction.copy.stableID == BuiltInAction.copy.stableID)
    #expect(Set(BuiltInAction.allCases.map(\.stableID)).count == BuiltInAction.allCases.count)
  }

  @Test func syncMergeIsLastWriterWins() {
    let base = TextAction(name: "A", icon: "x", kind: .url, template: "u", outputMode: .none, updatedAt: Date(timeIntervalSince1970: 10))
    var newer = base
    newer.name = "A2"
    newer.updatedAt = Date(timeIntervalSince1970: 20)
    let remoteOnly = TextAction(name: "B", icon: "x", kind: .url, template: "u", outputMode: .none)
    let merged = ActionStore.merge(local: [base], remote: [newer, remoteOnly])
    #expect(merged.map(\.name) == ["A2", "B"])
    #expect(ActionStore.merge(local: [newer], remote: [base]).map(\.name) == ["A2"])
  }

  @Test func actionFileImportGetsFreshIdentity() throws {
    let original = TextAction(name: "Share", icon: "x", kind: .javaScript, template: "return text", outputMode: .replace)
    let data = try ActionFile.export(original)
    let imported = try ActionFile.import(data)
    #expect(imported.name == "Share")
    #expect(imported.id != original.id)
    var future = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    future["format"] = 99
    #expect(throws: SelectaError.unsupportedFileFormat(99)) {
      try ActionFile.import(try JSONSerialization.data(withJSONObject: future))
    }
  }
}
