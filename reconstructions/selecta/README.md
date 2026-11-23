# Selecta

Selecta runs actions on selected text on Mac, iPhone, and iPad. It is a clean-room reconstruction
of the ActionClip feature set; see [ANALYSIS.md](ANALYSIS.md) for the reverse-engineering findings
it is based on.

## Layout

| Path                     | Platforms         | Contents                                                                                              |
| ------------------------ | ----------------- | ----------------------------------------------------------------------------------------------------- |
| `Sources/SelectaCore`    | macOS, iOS, Linux | Action model, templates, smart suggestions, conversions, AI clients, engine, store, shell/JS runners  |
| `Apps/Shared`            | macOS, iOS        | Observable model, Keychain, iCloud sync, SwiftUI action bar, library editor, AI settings, App Intents |
| `Apps/macOS`             | macOS             | Menu-bar app: AX selection monitor, floating panel, replace/paste bridge, AppleScript, hotkey         |
| `Apps/iOS`               | iOS               | App with native edit-menu scratchpad, library, settings, setup guide                                  |
| `Extensions/iOSAction`   | iOS               | Share-sheet Action extension                                                                          |
| `Extensions/iOSKeyboard` | iOS               | Action keyboard (replace in place)                                                                    |

## What works where

| Capability                                    | macOS                       | iOS                                                                  |
| --------------------------------------------- | --------------------------- | -------------------------------------------------------------------- |
| Floating bar on selection in any app          | Yes (Accessibility)         | No (OS limit). Uses the share sheet, keyboard, and Shortcuts instead |
| Replace selection in other apps               | AX set, then paste fallback | Keyboard only                                                        |
| Built-ins, AI prompt, URL, JavaScript actions | Yes                         | Yes                                                                  |
| Shell, AppleScript actions                    | Yes                         | Hidden                                                               |
| Shortcuts actions                             | `shortcuts run`             | Shortcuts URL / App Intent                                           |
| Apple Intelligence (on device)                | macOS 26+                   | iOS 26+                                                              |
| iCloud sync of actions                        | Key-value store             | Key-value store                                                      |

## Build

The core builds and tests anywhere Swift 6 runs:

```sh
swift test
```

The apps need Xcode on a Mac:

```sh
brew install xcodegen
xcodegen generate
open Selecta.xcodeproj
```

Before building:

1. Replace `com.example.selecta` and `group.com.example.selecta` in `project.yml` and in
   `Apps/Shared/SelectaModel.swift` (`SelectaIDs`).
2. Set `DEVELOPMENT_TEAM`.
3. Enable App Groups and iCloud key-value storage for the App IDs in the developer portal.

On macOS, grant Accessibility permission on first launch. Distribute the Mac app with a
Developer ID signature and notarization; it cannot run in the App Sandbox. The iOS app, its
extensions, and the keyboard are App Store compatible.

## Privacy defaults

- Online AI is off until the user turns on "Allow online actions" and enters a key.
- Keys are stored in the Keychain.
- Selected text is sent to the model as delimited data, separate from the instruction.
- Shell actions receive text through stdin and `$SELECTA_TEXT`. Placeholders are always shell-quoted.
- The macOS ⌘C fallback is opt-in and restores the clipboard afterwards.
