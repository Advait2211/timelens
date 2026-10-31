import AppKit
import TimeLensCore

/// Names and icons for bundle IDs.
@MainActor
final class AppDirectory {
    private var names: [String: String] = [:]
    private var paths: [String: String] = [:]
    private var icons: [String: NSImage] = [:]
    private(set) var declaredCategories: [String: String] = [:]

    func load(_ records: [AppRecord]) {
        for record in records { remember(record) }
    }

    func remember(_ record: AppRecord) {
        names[record.id] = record.name
        if !record.path.isEmpty { paths[record.id] = record.path }
        if !record.declaredCategory.isEmpty { declaredCategories[record.id] = record.declaredCategory }
    }

    func name(_ id: String) -> String {
        if let name = names[id] { return name }
        if id.hasPrefix("proc:") { return String(id.dropFirst(5)) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let bundle = Bundle(url: url)
            let name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            names[id] = name
            paths[id] = url.path
            return name
        }
        let last = id.split(separator: ".").last.map(String.init) ?? id
        names[id] = last
        return last
    }

    func icon(_ id: String) -> NSImage? {
        if let cached = icons[id] { return cached }
        let path = paths[id] ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[id] = icon
        return icon
    }

    var isBrowser: (String) -> Bool { { BrowserReader.family(of: $0) != nil } }

    /// Every app seen so far, by name.
    var allApps: [(id: String, name: String)] {
        names.map { ($0.key, $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
