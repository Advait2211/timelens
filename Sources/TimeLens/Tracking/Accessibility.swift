import AppKit
import ApplicationServices

/// Reads window titles and browser address bars through the Accessibility API. Every call has
/// a short messaging timeout so a hung app can't stall the tracker.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once) and opens the Accessibility pane.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = application(pid)
        if let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) { return window }
        return attribute(app, kAXMainWindowAttribute)
    }

    /// The title of the app's focused window, e.g. "main.swift — time_tracker_macOS".
    static func focusedWindowTitle(_ pid: pid_t) -> String? {
        guard isTrusted, let window = focusedWindow(pid) else { return nil }
        let title: String? = attribute(window, kAXTitleAttribute)
        return title?.isEmpty == false ? title : nil
    }

    // MARK: Address bars

    private static let addressHints = ["address", "url", "location", "search or enter", "search with", "smart search",
                                       "search or type", "enter address", "search the web"]

    /// A found address field, kept so the search doesn't repeat every second.
    private static var cachedField: (pid: pid_t, window: AXUIElement, field: AXUIElement)?
    private static let lock = NSLock()

    /// What the browser's address bar shows, or nil. Returns nil while you're typing in it
    /// (that's a search in progress, not the page you're on).
    static func addressBarValue(pid: pid_t) -> (value: String, windowTitle: String?)? {
        guard isTrusted, let window = focusedWindow(pid) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.3)
        let windowTitle: String? = attribute(window, kAXTitleAttribute)

        lock.lock()
        let cached = cachedField
        lock.unlock()
        if let cached, cached.pid == pid, CFEqual(cached.window, window), let value = fieldValue(cached.field) {
            return value.isEmpty ? nil : (value, windowTitle)
        }
        guard let field = findAddressField(in: window) else { return nil }
        lock.lock()
        cachedField = (pid, window, field)
        lock.unlock()
        guard let value = fieldValue(field), !value.isEmpty else { return nil }
        return (value, windowTitle)
    }

    /// The field's text — nil if it's being edited.
    private static func fieldValue(_ field: AXUIElement) -> String? {
        if let focused: Bool = attribute(field, kAXFocusedAttribute), focused { return nil }
        let value: String? = attribute(field, kAXValueAttribute)
        return value
    }

    private static func findAddressField(in window: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 700 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            if role == "AXTextField" || role == "AXComboBox" || role == "AXSearchField" {
                let identifier: String = attribute(element, "AXDOMIdentifier") ?? attribute(element, kAXIdentifierAttribute) ?? ""
                if identifier == "urlbar-input" || identifier.localizedCaseInsensitiveContains("address") || identifier.localizedCaseInsensitiveContains("url") {
                    return element
                }
                let hints = [
                    attribute(element, kAXDescriptionAttribute) as String?,
                    attribute(element, kAXPlaceholderValueAttribute) as String?,
                    attribute(element, kAXTitleAttribute) as String?,
                    attribute(element, kAXHelpAttribute) as String?,
                ].compactMap { $0?.lowercased() }
                if hints.contains(where: { hint in addressHints.contains { hint.contains($0) } }) {
                    return element
                }
            }
            // Page content never holds the address bar, and it's where most elements are.
            if role == "AXWebArea" || depth > 12 { continue }
            if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return nil
    }
}
