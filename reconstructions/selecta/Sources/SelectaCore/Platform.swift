import Foundation

/// What the current platform can actually do. iOS has no system-wide selection access, no shell,
/// and no AppleScript, so those action kinds are hidden there rather than failing at run time.
public struct PlatformCapabilities: Sendable {
  public var supportedKinds: Set<ActionKind>
  /// Whether the app can read and replace selections in other apps directly.
  public var hasSystemWideSelection: Bool

  public func supports(_ kind: ActionKind) -> Bool { supportedKinds.contains(kind) }

  public static let macOS = PlatformCapabilities(
    supportedKinds: Set(ActionKind.allCases), hasSystemWideSelection: true)

  public static let iOS = PlatformCapabilities(
    supportedKinds: [.builtIn, .aiPrompt, .url, .javaScript, .shortcut], hasSystemWideSelection: false)

  /// Linux is only used to test the core; treat it like macOS minus AppleScript.
  public static let linux = PlatformCapabilities(
    supportedKinds: [.builtIn, .aiPrompt, .url, .javaScript, .shell], hasSystemWideSelection: false)

  public static var current: PlatformCapabilities {
    #if os(macOS)
      .macOS
    #elseif os(iOS) || os(visionOS)
      .iOS
    #else
      .linux
    #endif
  }
}
