import AppKit

/// Fetches website icons straight from each site (never through a third-party icon service, so
/// no one else learns which sites you visit) and caches them on disk.
actor FaviconLoader {
    enum Kind: String, Sendable {
        /// apple-touch-icon: large and full-bleed, shown edge to edge.
        case touch
        /// favicon.ico: small, shown inset on a tile.
        case favicon
    }

    struct Icon: Sendable {
        let data: Data
        let kind: Kind
    }

    static let shared = FaviconLoader()

    private var memory: [String: Icon] = [:]
    private var tasks: [String: Task<Icon?, Never>] = [:]
    private let directory: URL
    private let session: URLSession

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.advait.timelens/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) TimeLens"]
        session = URLSession(configuration: configuration)
    }

    func icon(for domain: String) async -> Icon? {
        if let cached = memory[domain] { return cached }
        if let task = tasks[domain] { return await task.value }
        let task = Task { await load(domain) }
        tasks[domain] = task
        let icon = await task.value
        tasks[domain] = nil
        if let icon { memory[domain] = icon }
        return icon
    }

    private func load(_ domain: String) async -> Icon? {
        for kind in [Kind.touch, .favicon] {
            let file = directory.appendingPathComponent("\(domain).\(kind.rawValue)")
            if let data = try? Data(contentsOf: file), !data.isEmpty { return Icon(data: data, kind: kind) }
        }
        // Don't retry a site with no icon for a week.
        let missing = directory.appendingPathComponent("\(domain).missing")
        if let modified = (try? missing.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(modified) < 7 * 86_400 {
            return nil
        }

        let hosts = domain.hasPrefix("www.") || domain.split(separator: ".").count > 2 ? [domain] : [domain, "www." + domain]
        let candidates: [(String, Kind)] = hosts.flatMap { host in
            [("https://\(host)/apple-touch-icon.png", Kind.touch), ("https://\(host)/favicon.ico", Kind.favicon)]
        }
        for (address, kind) in candidates {
            guard let url = URL(string: address),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 512_000,
                  let image = NSImage(data: data), image.size.width >= 16 else { continue }
            try? data.write(to: directory.appendingPathComponent("\(domain).\(kind.rawValue)"))
            return Icon(data: data, kind: kind)
        }
        FileManager.default.createFile(atPath: missing.path, contents: Data())
        return nil
    }
}
