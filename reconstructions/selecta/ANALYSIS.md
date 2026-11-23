# ActionClip 2.4.1 (655): static analysis

This report covers how the shipped ActionClip macOS build implements selected-text actions. It is
the basis for Selecta, a clean-room reconstruction for both macOS and iOS. No ActionClip code, assets,
strings, or branding are reused.

## Target identity

| Item         | Value                                                                                                             |
| ------------ | ----------------------------------------------------------------------------------------------------------------- |
| Source       | Sparkle appcast `https://updates.actionclip.app/appcast.xml`, item 2.4.1 / build 655, published 10 Nov 2026       |
| Artifact     | `ActionClip-2.4.1-655.dmg`, 27,455,315 bytes (matches the appcast `length`)                                       |
| SHA-256      | `83af020186d96c2429163ad952fda41f74fe6190925268be8fca1aebf7938219`                                                |
| REA evidence | `inspect_artifact` `ev_799152f5…a07c`; inventory substep `ev_32c45627…8f62`                                       |
| Bundle       | `app.actionclip.ActionClip`, universal x86_64 + arm64, macOS 15.0 minimum, built with Xcode 27.2 / SDK macOS 27.2 |

## Method and limits

- **REA:** `inspect-artifact` recorded the DMG digest and identity. On Linux, REA reports that DMG
  child inventory needs a native macOS adapter. `inspect-macho`, `inspect-plist`, and
  `inspect-signature` returned `provider_unavailable` because no Ghidra, Hopper, or IDA was
  configured. No decompilation was performed.
- **Format-level parsing:** the DMG was extracted with 7-Zip. Info.plists and the provisioning
  profile were read with `plistlib`, load commands and the signature's entitlement blob with a
  Mach-O parser, and Swift reflection metadata (`__swift5_reflstr`, ObjC class names) with
  `llvm-objdump` and `strings`.
- **Not done:** the app was not run, so nothing here observes runtime behavior. Control flow inside
  functions (polling intervals, ranking weights, exact fallbacks) was not recovered. Recovering it
  needs Ghidra on the arm64 slice, or a macOS host with REA's native tools.

## Findings

Each finding is marked **O** (observed directly in the artifact), **I** (inferred from observed
names or APIs), or **U** (unknown).

### Packaging and distribution

- **O:** LSUIElement menu-bar app. Developer ID distribution with a Sparkle 2 updater (EdDSA-signed
  appcast; the feed is `appcast-v2.xml`).
- **O:** The main executable's signed entitlements have **no App Sandbox**. They include Apple Events
  automation, Contacts, Calendars, CloudKit (`iCloud.app.actionclip.ActionClip`), and push.
- **O:** It ships a separate `ActionClipJavaScriptService.xpc`, whose helper
  `ActionClipJavaScriptWorker` _is_ sandboxed. The worker embeds a URL/URLSearchParams polyfill and
  errors such as "Return text, a number, a boolean, an array, or an object."
- **I:** User JavaScript runs in a sandboxed, killable child process. This is isolation plus
  enforceable timeouts.

### Selection capture (macOS)

- **O:** Classes include `SelectionReader`, `AccessibilityManager`, `SelectionPollingScheduler`,
  `ClipboardOperationGate`, `LocalSelectionDiagnostics`, and `WidgetPointerEventRouter`.
- **O:** Strings include the AX attributes `AXFocusedUIElement`, `AXSelectedTextRange(s)`,
  `AXSelectedTextMarkerRange` (WebKit), and `AXBoundsForRange`, plus `CGEventCreate` and
  `NSEvent` monitors.
- **I:** Selection is read through Accessibility: the focused element, then its selected text,
  then its bounds for range. It is triggered by global input events with scheduled polling, and a
  clipboard-based fallback is guarded by a gate. Text-marker ranges suggest special handling for
  WebKit and Safari.
- **O:** The changelog says ⌘C keeps working "while ActionClip is still reading a new
  selection". It also mentions a Google Sheets fix where selection recovery had been cancelling an
  active cell edit.
- **I:** The fallback synthesizes key events into the source app, which has real side effects in
  web apps.

### Action model

- **O:** Action kinds from reflection: `builtIn aiPrompt url command appleScript javaScript
  shortcut keyPress transform`.
- **O:** Action fields: `name icon type description template isPinned isEnabled createdAt
  updatedAt aiGenerationPrompt triggerPattern marketplaceCategory shortcutConfiguration
  keyPressShortcut aiPromptAsksEachTime contextRules loadingPresentation outputMode`.
- **O:** Shareable action documents: UTI `app.actionclip.action` (`.actionclip`,
  `application/vnd.actionclip.action+json`) and a URL scheme `actionclip://` for marketplace installs.
- **O:** Template placeholders such as `{{url_encoded__selected_text}}` appear in bundled
  integrations.
- **O:** It bundles `POPCLIP-EXTENSIONS-LICENSE.txt` and strings describing reproductions of
  third-party PopClip integrations.
- **I:** Some marketplace actions are ports of PopClip extensions.

### AI

- **O:** Linked to `FoundationModels` (`SystemLanguageModel`, availability reasons
  `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`).
- **O:** Provider enum: `gemini openai openAICompatible claude openRouter perplexity ollamaCloud
  deepSeek groq miniMax githubModels claudeCode`, plus `ollamaLocal` and `appleIntelligence`.
- **O:** It also has `CodexAppServerClient` and `CodexAccountService`.
- **I:** It integrates with a locally installed coding-agent CLI as an AI source.

### Other subsystems (O, from class names)

- **UI:** `FloatingPanelController` and `ActionClipFloatingPanel` (non-activating panel); 4 themes;
  result popup with inline editor and conversation follow-ups.
- **Text features:** `ScreenshotOCRService` (Vision), `SequencePasteController`,
  `SavedSnippetStore`, `CurrencyRateService`, `TranslationReplySession` (Apple Translation
  framework), `SpellCheckerAccess`, `EdgeMP3StreamPlayer` and `SaySpeechPlaybackController` (speech).
- **Licensing and telemetry:** `LicenseStore`, `TrialUsageStore` (free tier is 30 runs/day per the
  site), `AnalyticsService`, `ICloudSyncService` (CloudKit).

### Unknowns

- **U:** How suggestions are ranked beyond regex triggers and value-type detection.
- **U:** The exact trigger heuristics and polling cadence for selection detection.
- **U:** The contents of `contextRules` and the marketplace catalog wire format (it is loaded at
  runtime and was not fetched).
- **U:** Whether replacement prefers AX value-setting or paste.
- **U:** Network endpoints for licensing and analytics (not enumerated).

## iOS feasibility (design constraint, not an ActionClip observation)

iOS gives no third-party app access to selections in other apps, and has no shell, AppleScript,
or global event taps. ActionClip ships no iOS build. Selecta reaches text on iOS through 4
supported routes:

| Route                                                  | Reads selection                  | Replaces in place                                        | Notes                                                    |
| ------------------------------------------------------ | -------------------------------- | -------------------------------------------------------- | -------------------------------------------------------- |
| Action extension (share sheet)                         | Yes, when the host shares text   | Only when the host accepts returned items; always copies | Works in most apps                                       |
| Custom keyboard                                        | `textDocumentProxy.selectedText` | Yes, with `insertText`                                   | The user switches keyboards; online AI needs Full Access |
| App Intents (Shortcuts, Siri, Action button, Back Tap) | Text parameter or clipboard      | No; returns and copies                                   | Good for repeat workflows                                |
| In-app editor                                          | Native `UITextView` edit menu    | Yes                                                      | The "iPhone-style" callout bar, natively                 |

## Reconstruction mapping

| Observed in ActionClip                                | Selecta                                                                                                    |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| AX selection reader + event monitors + clipboard gate | `Apps/macOS/SelectionMonitor.swift` (AX first; ⌘C fallback is opt-in and restores the pasteboard)          |
| Non-activating floating panel                         | `Apps/macOS/FloatingPanel.swift`                                                                           |
| Action kinds / output mode / trigger pattern          | `Sources/SelectaCore/TextAction.swift` (omits `keyPress` and `transform`, adds `shell`)                    |
| Template placeholders                                 | `TemplateResolver` (`{{text}}`, `{{url_encoded_text}}`, …); shell templates always quote                   |
| Sandboxed JS worker                                   | `JavaScriptRunner` (in-process JavaScriptCore; see limitation below)                                       |
| Apple Intelligence + BYO keys + Ollama                | `AIClients.swift`: FoundationModels, OpenAI-compatible (covers OpenRouter/Groq/DeepSeek/Ollama), Anthropic |
| CloudKit sync                                         | `NSUbiquitousKeyValueStore` with last-writer-wins merge (simpler; 1 MB cap)                                |
| `.actionclip` documents                               | `.selecta` files (`ActionFile`, versioned, imports get fresh IDs)                                          |

**Known gap:** JavaScriptCore cannot interrupt a running script, so an infinite loop occupies a
thread until the process exits. ActionClip avoids this with a killable sandboxed XPC worker, and
Selecta should adopt the same pattern on macOS before shipping untrusted marketplace scripts.
