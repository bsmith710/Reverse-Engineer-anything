import AppKit
import ApplicationServices
import SelectaCore

/// A selection read from another app through the Accessibility API.
struct ObservedSelection {
  var context: SelectionContext
  /// Selection bounds in Cocoa screen coordinates (bottom-left origin), when the app exposes them.
  var bounds: CGRect?
  /// The AX element holding the selection, used to replace text in place.
  var element: AXUIElement?
  var pid: pid_t
}

/// Watches for text selections system-wide.
///
/// Trigger: a mouse-up that ended a drag or a double/triple click, or a Shift+arrow key-up.
/// Reading: `kAXFocusedUIElement` → `kAXSelectedText`, bounds from `kAXBoundsForRangeParameterizedAttribute`.
/// Fallback (opt-in): synthesize ⌘C and restore the pasteboard, for apps that do not expose AX text.
@MainActor
final class SelectionMonitor {
  var onSelection: ((ObservedSelection) -> Void)?
  var onDismiss: (() -> Void)?
  var excludedBundleIDs: Set<String> = []
  var useClipboardFallback = false

  private var monitors: [Any] = []
  private var mouseDownLocation: NSPoint = .zero
  private var pending: Task<Void, Never>?

  static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Shows the system Accessibility prompt if needed.
  static func requestTrust() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  func start() {
    stop()
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        MainActor.assumeIsolated {
          self?.mouseDownLocation = NSEvent.mouseLocation
          self?.onDismiss?()
        }
      } as Any)
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
        let clicks = event.clickCount
        MainActor.assumeIsolated {
          guard let self else { return }
          let moved = hypot(NSEvent.mouseLocation.x - self.mouseDownLocation.x, NSEvent.mouseLocation.y - self.mouseDownLocation.y)
          if moved > 4 || clicks >= 2 { self.schedule() }
        }
      } as Any)
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
        let shiftArrow = event.modifierFlags.contains(.shift) && (123...126).contains(event.keyCode)
        let selectAll = event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "a"
        MainActor.assumeIsolated {
          if shiftArrow || selectAll { self?.schedule() } else { self?.onDismiss?() }
        }
      } as Any)
  }

  func stop() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors.removeAll()
  }

  /// Reads the current selection immediately (used by the global hotkey).
  func readNow() async -> ObservedSelection? {
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier != Bundle.main.bundleIdentifier,
      !excludedBundleIDs.contains(app.bundleIdentifier ?? "")
    else { return nil }
    if let ax = Self.readAccessibilitySelection(app: app) { return ax }
    if useClipboardFallback, let text = await ClipboardProbe.copySelection() {
      return ObservedSelection(
        context: SelectionContext(text: text, sourceAppName: app.localizedName, sourceBundleID: app.bundleIdentifier, isEditable: false),
        bounds: nil, element: nil, pid: app.processIdentifier)
    }
    return nil
  }

  private func schedule() {
    pending?.cancel()
    pending = Task { [weak self] in
      // Let the source app finish updating its selection before reading it.
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard !Task.isCancelled, let self, let selection = await self.readNow(),
        !selection.context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      self.onSelection?(selection)
    }
  }

  static func readAccessibilitySelection(app: NSRunningApplication) -> ObservedSelection? {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 0.25)
    guard let focused: AXUIElement = copyAttribute(appElement, kAXFocusedUIElementAttribute) else { return nil }
    guard let text: String = copyAttribute(focused, kAXSelectedTextAttribute), !text.isEmpty else { return nil }

    var settable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable)

    var bounds: CGRect?
    if let rangeValue: AXValue = copyAttribute(focused, kAXSelectedTextRangeAttribute) {
      var boundsRef: CFTypeRef?
      if AXUIElementCopyParameterizedAttributeValue(
        focused, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef) == .success,
        let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID()
      {
        var rect = CGRect.zero
        // swiftlint:disable:next force_cast
        if AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 {
          bounds = flipToCocoa(rect)
        }
      }
    }
    return ObservedSelection(
      context: SelectionContext(
        text: text, sourceAppName: app.localizedName, sourceBundleID: app.bundleIdentifier, isEditable: settable.boolValue),
      bounds: bounds, element: focused, pid: app.processIdentifier)
  }

  private static func copyAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
  }

  /// AX uses a top-left origin on the primary display; Cocoa uses bottom-left.
  private static func flipToCocoa(_ rect: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }
}

/// Copies the selection with a synthesized ⌘C and restores the previous pasteboard contents.
enum ClipboardProbe {
  @MainActor
  static func copySelection() async -> String? {
    let pasteboard = NSPasteboard.general
    let snapshot = PasteboardSnapshot(pasteboard)
    let before = pasteboard.changeCount
    KeySender.send(key: 8, flags: .maskCommand)  // kVK_ANSI_C
    for _ in 0..<15 {
      try? await Task.sleep(nanoseconds: 20_000_000)
      if pasteboard.changeCount != before { break }
    }
    defer { snapshot.restore(to: pasteboard) }
    guard pasteboard.changeCount != before else { return nil }
    return pasteboard.string(forType: .string)
  }
}

/// Saves and restores every item and type on a pasteboard.
struct PasteboardSnapshot {
  private let items: [[NSPasteboard.PasteboardType: Data]]

  init(_ pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
    }
  }

  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let restored = items.map { types -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in types { item.setData(data, forType: type) }
      return item
    }
    if !restored.isEmpty { pasteboard.writeObjects(restored) }
  }
}

enum KeySender {
  static func send(key: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
      event?.flags = flags
      event?.post(tap: .cghidEventTap)
    }
  }
}
