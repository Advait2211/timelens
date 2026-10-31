import Foundation

/// A browser address boiled down to what TimeLens stores.
public struct ParsedURL: Equatable, Sendable {
    /// The website time is credited to: `github.com`, `mail.google.com`, `localhost:3000`, or
    /// one of the `SiteKey` pseudo-sites.
    public let site: String
    /// The full host, minus `www.` and friends.
    public let host: String
    /// Host and path, with no scheme, query or fragment — `github.com/apple/swift`.
    public let page: String
}

/// Turns browser URLs into website keys.
public enum SiteKey {
    /// Time in a private or incognito window: no site, URL or title is kept.
    public static let privateSite = "__private__"
    /// New tab pages, settings, history, extensions.
    public static let browserPages = "__browser__"
    /// Local files opened in the browser.
    public static let localFiles = "__file__"

    public static func isPseudo(_ site: String) -> Bool { site.hasPrefix("__") }

    public static func displayName(_ site: String) -> String {
        switch site {
        case privateSite: "Private browsing"
        case browserPages: "Browser pages"
        case localFiles: "Local files"
        case "": "—"
        default: site
        }
    }

    /// Parses what a browser reports, which may be a full URL or what the address bar shows
    /// (`github.com/foo`, with the scheme hidden). Returns nil for empty or unusable input.
    public static func parse(_ raw: String) -> ParsedURL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "missing value" else { return nil }

        if let colon = text.firstIndex(of: ":") {
            let scheme = text[..<colon].lowercased()
            if internalSchemes.contains(scheme) {
                return ParsedURL(site: browserPages, host: "", page: String(text.prefix(200)))
            }
            if scheme == "file" {
                return ParsedURL(site: localFiles, host: "", page: "")
            }
        }

        let withScheme = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: withScheme) ?? URLComponents(string: withScheme.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let rawHost = components.host, !rawHost.isEmpty else {
            return nil
        }
        let scheme = components.scheme?.lowercased() ?? "https"
        guard scheme == "http" || scheme == "https" else {
            return internalSchemes.contains(scheme) ? ParsedURL(site: browserPages, host: "", page: "") : nil
        }

        var host = normalizeHost(rawHost)
        guard !host.isEmpty, host.contains(".") || host == "localhost" || isIPAddress(host) else { return nil }
        // Local dev servers are told apart by port.
        if let port = components.port, isLocal(host) {
            host += ":\(port)"
        }

        var path = components.percentEncodedPath
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        let page = String((host + path).prefix(300))
        return ParsedURL(site: site(forHost: host), host: host, page: page)
    }

    /// Lowercased, without `www.`, `m.` and similar mobile/AMP prefixes.
    public static func normalizeHost(_ host: String) -> String {
        var result = host.lowercased()
        if result.hasSuffix(".") { result.removeLast() }
        for prefix in ["www.", "www2.", "m.", "mobile.", "amp."] where result.hasPrefix(prefix) {
            let rest = String(result.dropFirst(prefix.count))
            if rest.contains(".") { result = rest }
            break
        }
        return result
    }

    /// The registrable part of a host — `en.wikipedia.org` → `wikipedia.org` — except where a
    /// subdomain is a different product (`mail.google.com`, `music.youtube.com`) or a different
    /// person's site (`someone.github.io`).
    public static func site(forHost host: String) -> String {
        if isLocal(host) || isIPAddress(host.split(separator: ":").first.map(String.init) ?? host) { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }

        let lastTwo = labels.suffix(2).joined(separator: ".")
        let lastThree = labels.suffix(3).joined(separator: ".")

        if keepSubdomains.contains(lastTwo) {
            return host
        }
        if platformSuffixes.contains(lastTwo) || multiPartSuffixes.contains(lastTwo) {
            return lastThree
        }
        if platformSuffixes.contains(lastThree), labels.count > 3 {
            return labels.suffix(4).joined(separator: ".")
        }
        return lastTwo
    }

    public static func isLocal(_ host: String) -> Bool {
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        return bare == "localhost" || bare.hasSuffix(".localhost") || bare == "127.0.0.1" || bare == "0.0.0.0" || bare == "::1"
    }

    static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return host.contains(":") && host.allSatisfy { $0.isHexDigit || $0 == ":" }
    }

    static let internalSchemes: Set<String> = [
        "about", "chrome", "brave", "edge", "arc", "vivaldi", "opera", "safari-resource",
        "chrome-extension", "moz-extension", "safari-web-extension", "view-source", "devtools",
        "chrome-search", "chrome-untrusted", "favorites", "bookmarks", "topsites",
    ]

    /// Where every subdomain is its own product.
    static let keepSubdomains: Set<String> = [
        "google.com", "youtube.com", "apple.com", "microsoft.com", "live.com", "office.com",
        "amazon.com", "aws.amazon.com", "atlassian.net", "slack.com", "zoom.us",
    ]

    /// Hosting platforms where the subdomain is someone's own site.
    static let platformSuffixes: Set<String> = [
        "github.io", "gitlab.io", "vercel.app", "netlify.app", "pages.dev", "herokuapp.com",
        "web.app", "firebaseapp.com", "blogspot.com", "substack.com", "notion.site",
        "wordpress.com", "streamlit.app", "onrender.com", "glitch.me", "replit.app", "hf.space",
        "fly.dev", "railway.app", "surge.sh", "neocities.org", "tumblr.com", "itch.io",
        "readthedocs.io", "gitbook.io", "framer.website", "webflow.io", "carrd.co",
    ]

    /// Country-code second levels, where the site is three labels long.
    static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "co.in", "org.in", "ac.in", "gov.in", "net.in",
        "edu.in", "res.in", "nic.in", "com.au", "net.au", "org.au", "edu.au", "co.jp", "ne.jp",
        "co.nz", "com.br", "com.cn", "com.sg", "edu.sg", "co.za", "com.mx", "com.tr", "co.kr",
        "com.hk", "com.tw", "co.id", "com.my", "com.pk", "com.bd", "com.ar", "com.ng",
    ]
}

/// Cleans window and page titles for display and grouping.
public enum TitleCleaner {
    /// Drops unread counters (`(3) Inbox`), the browser's own name, and stray whitespace.
    public static func clean(_ raw: String?, appName: String? = nil) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        // "(12) YouTube", "[3] Discord", "• Slack" counters change constantly; they'd split one
        // page into many.
        if let match = title.range(of: #"^(\(\d+\+?\)|\[\d+\+?\]|•|●)\s*"#, options: .regularExpression) {
            title.removeSubrange(match)
        }
        let suffixes = [" - Google Chrome", " — Google Chrome", " - Brave", " — Brave", " - Microsoft Edge",
                        " — Mozilla Firefox", " - Mozilla Firefox", " — Firefox", " — Zen Browser", " - Arc"]
        for suffix in suffixes where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
            break
        }
        if let appName, title.hasSuffix(" - \(appName)") { title.removeLast(appName.count + 3) }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(240))
    }
}
