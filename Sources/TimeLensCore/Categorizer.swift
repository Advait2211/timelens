import Foundation

/// What kind of time something is. Eight categories plus Other — one per slot of the chart
/// palette, so a category keeps its color everywhere.
public enum Category: String, CaseIterable, Codable, Sendable, Identifiable {
    case development, social, productivity, entertainment, communication, learning, creativity, games, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .development: "Development"
        case .social: "Social"
        case .productivity: "Productivity"
        case .entertainment: "Entertainment"
        case .communication: "Communication"
        case .learning: "Learning & Reading"
        case .creativity: "Creativity"
        case .games: "Games"
        case .other: "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .development: "chevron.left.forwardslash.chevron.right"
        case .social: "person.2.fill"
        case .productivity: "checklist"
        case .entertainment: "play.rectangle.fill"
        case .communication: "bubble.left.and.bubble.right.fill"
        case .learning: "book.fill"
        case .creativity: "paintbrush.pointed.fill"
        case .games: "gamecontroller.fill"
        case .other: "square.grid.2x2.fill"
        }
    }

    public var defaultRating: Rating {
        switch self {
        case .development, .productivity, .learning, .creativity: .productive
        case .communication, .other: .neutral
        case .social, .entertainment, .games: .distracting
        }
    }
}

public enum Rating: Int, CaseIterable, Codable, Sendable, Identifiable {
    case distracting = -1, neutral = 0, productive = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .productive: "Productive"
        case .neutral: "Neutral"
        case .distracting: "Distracting"
        }
    }

    /// Weight in the productivity score (0–100).
    public var score: Double {
        switch self {
        case .productive: 100
        case .neutral: 50
        case .distracting: 0
        }
    }
}

/// A user's choice for one app, site or category.
public struct Override: Codable, Hashable, Sendable {
    public var category: Category?
    public var rating: Rating?

    public init(category: Category? = nil, rating: Rating? = nil) {
        self.category = category
        self.rating = rating
    }

    public static func appKey(_ bundleID: String) -> String { "app:" + bundleID }
    public static func siteKey(_ site: String) -> String { "site:" + site }
    public static func categoryKey(_ category: Category) -> String { "category:" + category.rawValue }
}

/// Decides the category and rating of a stretch of time. Websites decide for browser time;
/// otherwise the app does. User overrides win, then the built-in tables, then the category
/// the app declares in its Info.plist.
public struct Categorizer: Sendable {
    public var overrides: [String: Override]
    /// Bundle ID → LSApplicationCategoryType, supplied by the app (which can read bundles).
    public var declaredCategories: [String: String]

    public init(overrides: [String: Override] = [:], declaredCategories: [String: String] = [:]) {
        self.overrides = overrides
        self.declaredCategories = declaredCategories
    }

    public func category(app: String, site: String) -> Category {
        if !site.isEmpty { return siteCategory(site) }
        return appCategory(app)
    }

    public func appCategory(_ bundleID: String) -> Category {
        if let chosen = overrides[Override.appKey(bundleID)]?.category { return chosen }
        if let known = Self.builtInCategory(app: bundleID) { return known }
        if let declared = declaredCategories[bundleID], let mapped = Self.declaredMapping[declared] { return mapped }
        return .other
    }

    public func siteCategory(_ site: String) -> Category {
        if let chosen = overrides[Override.siteKey(site)]?.category { return chosen }
        if SiteKey.isPseudo(site) { return .other }
        return Self.builtInCategory(site: site) ?? .other
    }

    public func rating(app: String, site: String) -> Rating {
        let key = site.isEmpty ? Override.appKey(app) : Override.siteKey(site)
        if let chosen = overrides[key]?.rating { return chosen }
        return rating(of: category(app: app, site: site))
    }

    public func rating(of category: Category) -> Rating {
        overrides[Override.categoryKey(category)]?.rating ?? category.defaultRating
    }

    // MARK: Built-in knowledge

    public static func builtInCategory(app bundleID: String) -> Category? {
        if let exact = apps[bundleID] { return exact }
        for (prefix, category) in appPrefixes where bundleID.hasPrefix(prefix) { return category }
        return nil
    }

    public static func builtInCategory(site: String) -> Category? {
        if let exact = sites[site] { return exact }
        // `docs.python.org` → `python.org`, `colab.research.google.com` → `research.google.com`.
        var labels = site.split(separator: ".")
        while labels.count > 2 {
            labels.removeFirst()
            if let parent = sites[labels.joined(separator: ".")] { return parent }
        }
        if site.hasSuffix(".edu") || site.hasSuffix(".ac.in") || site.hasSuffix(".edu.in") || site.hasSuffix(".ac.uk") { return .learning }
        if site.hasSuffix(".github.io") || site.hasSuffix(".readthedocs.io") || site.hasPrefix("localhost") || site.hasPrefix("127.0.0.1") { return .development }
        return nil
    }

    static let declaredMapping: [String: Category] = [
        "public.app-category.developer-tools": .development,
        "public.app-category.productivity": .productivity,
        "public.app-category.business": .productivity,
        "public.app-category.finance": .productivity,
        "public.app-category.utilities": .other,
        "public.app-category.social-networking": .social,
        "public.app-category.entertainment": .entertainment,
        "public.app-category.music": .entertainment,
        "public.app-category.video": .entertainment,
        "public.app-category.sports": .entertainment,
        "public.app-category.news": .learning,
        "public.app-category.education": .learning,
        "public.app-category.reference": .learning,
        "public.app-category.books": .learning,
        "public.app-category.graphics-design": .creativity,
        "public.app-category.photography": .creativity,
        "public.app-category.music-creation": .creativity,
        "public.app-category.video-editing": .creativity,
        "public.app-category.games": .games,
        "public.app-category.action-games": .games,
        "public.app-category.adventure-games": .games,
        "public.app-category.arcade-games": .games,
        "public.app-category.board-games": .games,
        "public.app-category.card-games": .games,
        "public.app-category.casino-games": .games,
        "public.app-category.dice-games": .games,
        "public.app-category.educational-games": .games,
        "public.app-category.family-games": .games,
        "public.app-category.kids-games": .games,
        "public.app-category.music-games": .games,
        "public.app-category.puzzle-games": .games,
        "public.app-category.racing-games": .games,
        "public.app-category.role-playing-games": .games,
        "public.app-category.simulation-games": .games,
        "public.app-category.sports-games": .games,
        "public.app-category.strategy-games": .games,
        "public.app-category.trivia-games": .games,
        "public.app-category.word-games": .games,
        "public.app-category.lifestyle": .other,
        "public.app-category.travel": .other,
        "public.app-category.weather": .other,
        "public.app-category.healthcare-fitness": .other,
        "public.app-category.medical": .other,
        "public.app-category.shopping": .other,
    ]

    static let appPrefixes: [(String, Category)] = [
        ("com.jetbrains.", .development),
        ("com.microsoft.VSCode", .development),
        ("com.google.android.studio", .development),
        ("com.apple.dt.", .development),
        ("com.adobe.", .creativity),
        ("com.valvesoftware.", .games),
        ("com.epicgames.", .games),
        ("com.riotgames.", .games),
        ("com.blizzard.", .games),
    ]

    static let apps: [String: Category] = [
        // Development
        "com.apple.Terminal": .development, "com.googlecode.iterm2": .development,
        "dev.warp.Warp-Stable": .development, "com.mitchellh.ghostty": .development,
        "net.kovidgoyal.kitty": .development, "io.alacritty": .development, "com.github.wez.wezterm": .development,
        "com.microsoft.VSCode": .development, "com.microsoft.VSCodeInsiders": .development,
        "com.todesktop.230313mzl4w4u92": .development, // Cursor
        "dev.zed.Zed": .development, "com.exafunction.windsurf": .development,
        "com.sublimetext.4": .development, "com.sublimetext.3": .development, "com.panic.Nova": .development,
        "com.apple.dt.Xcode": .development, "com.github.GitHubClient": .development,
        "com.sublimemerge": .development, "com.fournova.Tower3": .development, "com.axosoft.gitkraken": .development,
        "com.postmanlabs.mac": .development, "com.insomnia.app": .development, "com.docker.docker": .development,
        "com.tinyapp.TablePlus": .development, "com.sequel-ace.sequel-ace": .development,
        "org.vim.MacVim": .development, "org.gnu.Emacs": .development, "com.neovide.neovide": .development,
        "com.anthropic.claudefordesktop": .productivity, "com.openai.chat": .productivity,
        "com.apple.ScriptEditor2": .development, "com.apple.Automator": .development,
        "com.utmapp.UTM": .development, "com.parallels.desktop.console": .development,
        "org.wireshark.Wireshark": .development, "com.jupyter.lab": .development,
        // Productivity
        "notion.id": .productivity, "md.obsidian": .productivity, "com.apple.Notes": .productivity,
        "com.apple.reminders": .productivity, "com.apple.iCal": .productivity, "com.apple.iWork.Pages": .productivity,
        "com.apple.iWork.Numbers": .productivity, "com.apple.iWork.Keynote": .productivity,
        "com.microsoft.Word": .productivity, "com.microsoft.Excel": .productivity, "com.microsoft.Powerpoint": .productivity,
        "com.microsoft.onenote.mac": .productivity, "com.culturedcode.ThingsMac": .productivity,
        "com.todoist.mac.Todoist": .productivity, "com.linear": .productivity, "com.figma.Desktop": .creativity,
        "com.apple.finder": .other, "com.apple.Preview": .productivity, "com.readdle.PDFExpert-Mac": .productivity,
        "com.raycast.macos": .other, "com.apple.Spotlight": .other, "com.apple.TextEdit": .productivity,
        "com.agiletortoise.Drafts-OSX": .productivity, "net.shinyfrog.bear": .productivity,
        "com.lukilabs.lukiapp": .productivity, "com.logseq.logseq": .productivity, "abnerworks.Typora": .productivity,
        "org.zotero.zotero": .learning, "com.mendeley.desktop": .learning, "com.apple.iBooksX": .learning,
        "net.cozic.joplin-desktop": .productivity, "com.superhuman.electron": .communication,
        "com.apple.mail": .communication, "com.microsoft.Outlook": .communication, "com.readdle.smartemail-Mac": .communication,
        "com.google.Chrome.app.Default-mail": .communication,
        // Communication
        "com.apple.MobileSMS": .communication, "net.whatsapp.WhatsApp": .communication, "desktop.WhatsApp": .communication,
        "ru.keepcoder.Telegram": .communication, "org.telegram.desktop": .communication, "com.tdesktop.Telegram": .communication,
        "com.tinyspeck.slackmacgap": .communication, "com.hnc.Discord": .communication, "com.microsoft.teams2": .communication,
        "com.microsoft.teams": .communication, "us.zoom.xos": .communication, "com.apple.FaceTime": .communication,
        "org.whispersystems.signal-desktop": .communication, "com.facebook.archon": .communication,
        "com.skype.skype": .communication, "com.google.Chrome.app.meet": .communication, "com.apple.AddressBook": .communication,
        // Social
        "com.atebits.Tweetie2": .social, "maccatalyst.com.atebits.Tweetie2": .social, "com.reddit.Reddit": .social,
        "com.burbn.instagram": .social, "com.linkedin.LinkedIn": .social, "com.mastodon.Ivory": .social,
        "com.tapbots.Ivory": .social, "xyz.blueskyweb.app": .social,
        // Entertainment
        "com.spotify.client": .entertainment, "com.apple.Music": .entertainment, "com.apple.TV": .entertainment,
        "com.apple.podcasts": .entertainment, "com.netflix.Netflix": .entertainment, "org.videolan.vlc": .entertainment,
        "com.colliderli.iina": .entertainment, "com.apple.QuickTimePlayerX": .entertainment,
        "tv.plex.desktop": .entertainment, "com.amazon.aiv.AIVApp": .entertainment, "com.disney.disneyplus": .entertainment,
        "com.google.Chrome.app.youtube": .entertainment, "com.apple.news": .learning, "com.apple.stocks": .other,
        // Creativity
        "com.bohemiancoding.sketch3": .creativity, "com.pixelmatorteam.pixelmator.x": .creativity,
        "com.seriflabs.affinitydesigner2": .creativity, "com.seriflabs.affinityphoto2": .creativity,
        "com.apple.FinalCut": .creativity, "com.apple.logic10": .creativity, "com.apple.garageband10": .creativity,
        "com.blackmagic-design.DaVinciResolve": .creativity, "org.blenderfoundation.blender": .creativity,
        "com.apple.Photos": .creativity, "com.apple.iMovieApp": .creativity, "com.canva.CanvaDesktop": .creativity,
        "com.obsproject.obs-studio": .creativity, "com.lemon.lvoverseas": .creativity,
        // Games
        "com.valvesoftware.steam": .games, "com.apple.Chess": .games, "com.mojang.minecraftlauncher": .games,
        "com.apple.games": .games, "com.apple.gamecenter": .games, "net.battle.app": .games,
        // System / other
        "com.apple.systempreferences": .other, "com.apple.ActivityMonitor": .other, "com.apple.AppStore": .other,
        "com.apple.Passwords": .other, "com.1password.1password": .other, "com.bitwarden.desktop": .other,
        "com.apple.calculator": .other, "com.apple.archiveutility": .other, "com.apple.ScreenSharing": .other,
        "com.apple.Maps": .other, "com.apple.weather": .other, "com.apple.clock": .other,
    ]

    static let sites: [String: Category] = [
        // Development
        "github.com": .development, "gitlab.com": .development, "bitbucket.org": .development,
        "stackoverflow.com": .development, "stackexchange.com": .development, "superuser.com": .development,
        "serverfault.com": .development, "askubuntu.com": .development, "developer.apple.com": .development,
        "developer.mozilla.org": .development, "npmjs.com": .development, "pypi.org": .development,
        "crates.io": .development, "docs.rs": .development, "pkg.go.dev": .development, "go.dev": .development,
        "rust-lang.org": .development, "python.org": .development, "swift.org": .development,
        "kotlinlang.org": .development, "typescriptlang.org": .development, "react.dev": .development,
        "nextjs.org": .development, "vuejs.org": .development, "svelte.dev": .development, "tailwindcss.com": .development,
        "vercel.com": .development, "netlify.com": .development, "render.com": .development, "railway.app": .development,
        "heroku.com": .development, "cloudflare.com": .development, "dash.cloudflare.com": .development,
        "console.cloud.google.com": .development, "cloud.google.com": .development, "console.aws.amazon.com": .development,
        "aws.amazon.com": .development, "portal.azure.com": .development, "firebase.google.com": .development,
        "console.firebase.google.com": .development, "supabase.com": .development, "docker.com": .development,
        "hub.docker.com": .development, "kubernetes.io": .development, "huggingface.co": .development,
        "kaggle.com": .development, "colab.research.google.com": .development, "pytorch.org": .development,
        "tensorflow.org": .development, "numpy.org": .development, "pandas.pydata.org": .development,
        "scikit-learn.org": .development, "jupyter.org": .development, "replit.com": .development,
        "codepen.io": .development, "codesandbox.io": .development, "jsfiddle.net": .development,
        "leetcode.com": .development, "codeforces.com": .development, "codechef.com": .development,
        "atcoder.jp": .development, "hackerrank.com": .development, "hackerearth.com": .development,
        "cses.fi": .development, "geeksforgeeks.org": .learning, "cp-algorithms.com": .development,
        "usaco.guide": .development, "topcoder.com": .development, "kattis.com": .development,
        "regex101.com": .development, "jwt.io": .development, "postman.com": .development,
        "sentry.io": .development, "linear.app": .productivity, "jira.atlassian.com": .productivity,
        "atlassian.net": .productivity, "sourcegraph.com": .development, "godbolt.org": .development,
        "mujoco.org": .development, "ros.org": .development, "arduino.cc": .development,
        "anthropic.com": .development, "console.anthropic.com": .development, "platform.openai.com": .development,
        "docs.anthropic.com": .development, "wandb.ai": .development, "paperswithcode.com": .learning,
        "devdocs.io": .development, "w3schools.com": .learning, "freecodecamp.org": .learning,
        // AI assistants
        "claude.ai": .productivity, "chatgpt.com": .productivity, "chat.openai.com": .productivity,
        "gemini.google.com": .productivity, "perplexity.ai": .productivity, "chat.deepseek.com": .productivity,
        "grok.com": .productivity, "copilot.microsoft.com": .productivity, "poe.com": .productivity,
        // Productivity
        "docs.google.com": .productivity, "drive.google.com": .productivity, "sheets.google.com": .productivity,
        "slides.google.com": .productivity, "calendar.google.com": .productivity, "keep.google.com": .productivity,
        "notion.so": .productivity, "notion.site": .productivity, "trello.com": .productivity, "asana.com": .productivity,
        "monday.com": .productivity, "clickup.com": .productivity, "todoist.com": .productivity,
        "airtable.com": .productivity, "dropbox.com": .productivity, "box.com": .productivity,
        "onedrive.live.com": .productivity, "office.com": .productivity, "www.office.com": .productivity,
        "overleaf.com": .productivity, "miro.com": .productivity, "excalidraw.com": .creativity,
        "translate.google.com": .productivity, "grammarly.com": .productivity, "zotero.org": .learning,
        "icloud.com": .productivity, "1password.com": .other, "bitwarden.com": .other,
        // Communication
        "mail.google.com": .communication, "outlook.live.com": .communication, "outlook.office.com": .communication,
        "outlook.office365.com": .communication, "web.whatsapp.com": .communication, "whatsapp.com": .communication,
        "web.telegram.org": .communication, "telegram.org": .communication, "slack.com": .communication,
        "app.slack.com": .communication, "discord.com": .communication, "meet.google.com": .communication,
        "zoom.us": .communication, "teams.microsoft.com": .communication, "teams.live.com": .communication,
        "messenger.com": .communication, "proton.me": .communication, "mail.proton.me": .communication,
        "chat.google.com": .communication, "contacts.google.com": .communication,
        // Social
        "x.com": .social, "twitter.com": .social, "reddit.com": .social, "old.reddit.com": .social,
        "instagram.com": .social, "facebook.com": .social, "linkedin.com": .social, "threads.net": .social,
        "threads.com": .social, "bsky.app": .social, "mastodon.social": .social, "tumblr.com": .social,
        "pinterest.com": .social, "snapchat.com": .social, "tiktok.com": .entertainment, "quora.com": .social,
        "news.ycombinator.com": .social, "ycombinator.com": .learning, "lobste.rs": .social,
        "9gag.com": .entertainment, "imgur.com": .entertainment, "discord.gg": .communication,
        // Entertainment
        "youtube.com": .entertainment, "music.youtube.com": .entertainment, "youtu.be": .entertainment,
        "netflix.com": .entertainment, "primevideo.com": .entertainment, "hotstar.com": .entertainment,
        "jiocinema.com": .entertainment, "jiohotstar.com": .entertainment, "sonyliv.com": .entertainment,
        "zee5.com": .entertainment, "disneyplus.com": .entertainment, "hulu.com": .entertainment,
        "max.com": .entertainment, "hbomax.com": .entertainment, "tv.apple.com": .entertainment,
        "music.apple.com": .entertainment, "twitch.tv": .entertainment, "kick.com": .entertainment,
        "spotify.com": .entertainment, "open.spotify.com": .entertainment, "soundcloud.com": .entertainment,
        "gaana.com": .entertainment, "jiosaavn.com": .entertainment, "crunchyroll.com": .entertainment,
        "imdb.com": .entertainment, "letterboxd.com": .entertainment, "vimeo.com": .entertainment,
        "dailymotion.com": .entertainment, "9anime.to": .entertainment, "myanimelist.net": .entertainment,
        "webtoons.com": .entertainment, "espncricinfo.com": .entertainment, "cricbuzz.com": .entertainment,
        "espn.com": .entertainment, "chess.com": .games, "lichess.org": .games,
        // Games
        "store.steampowered.com": .games, "steampowered.com": .games, "steamcommunity.com": .games,
        "epicgames.com": .games, "roblox.com": .games, "miniclip.com": .games, "poki.com": .games,
        "crazygames.com": .games, "geoguessr.com": .games, "nytimes.com/games": .games, "itch.io": .games,
        // Learning & reading
        "wikipedia.org": .learning, "wikimedia.org": .learning, "wiktionary.org": .learning,
        "coursera.org": .learning, "edx.org": .learning, "udemy.com": .learning, "khanacademy.org": .learning,
        "nptel.ac.in": .learning, "swayam.gov.in": .learning, "mit.edu": .learning, "ocw.mit.edu": .learning,
        "stanford.edu": .learning, "arxiv.org": .learning, "scholar.google.com": .learning,
        "semanticscholar.org": .learning, "researchgate.net": .learning, "ieee.org": .learning,
        "ieeexplore.ieee.org": .learning, "acm.org": .learning, "dl.acm.org": .learning, "springer.com": .learning,
        "sciencedirect.com": .learning, "nature.com": .learning, "jstor.org": .learning, "medium.com": .learning,
        "substack.com": .learning, "dev.to": .learning, "hashnode.com": .learning, "brilliant.org": .learning,
        "duolingo.com": .learning, "quizlet.com": .learning, "chegg.com": .learning, "byjus.com": .learning,
        "unacademy.com": .learning, "vjti.ac.in": .learning, "classroom.google.com": .learning,
        "moodle.org": .learning, "3blue1brown.com": .learning, "mathworld.wolfram.com": .learning,
        "wolframalpha.com": .learning, "desmos.com": .learning, "goodreads.com": .learning,
        "nytimes.com": .learning, "theguardian.com": .learning, "bbc.com": .learning, "bbc.co.uk": .learning,
        "thehindu.com": .learning, "indianexpress.com": .learning, "hindustantimes.com": .learning,
        "timesofindia.indiatimes.com": .learning, "indiatimes.com": .learning, "ndtv.com": .learning,
        "reuters.com": .learning, "apnews.com": .learning, "bloomberg.com": .learning, "economist.com": .learning,
        "theverge.com": .learning, "arstechnica.com": .learning, "techcrunch.com": .learning, "wired.com": .learning,
        "livemint.com": .learning, "moneycontrol.com": .productivity, "economictimes.indiatimes.com": .learning,
        // Creativity
        "figma.com": .creativity, "canva.com": .creativity, "dribbble.com": .creativity, "behance.net": .creativity,
        "photopea.com": .creativity, "adobe.com": .creativity, "framer.com": .creativity, "unsplash.com": .creativity,
        "coolors.co": .creativity, "fonts.google.com": .creativity, "midjourney.com": .creativity,
        // Shopping, finance, misc → other
        "amazon.com": .other, "amazon.in": .other, "flipkart.com": .other, "myntra.com": .other,
        "ebay.com": .other, "aliexpress.com": .other, "swiggy.com": .other, "zomato.com": .other,
        "zerodha.com": .productivity, "kite.zerodha.com": .productivity, "console.zerodha.com": .productivity,
        "tradingview.com": .productivity, "groww.in": .productivity, "fyers.in": .productivity,
        "google.com": .other, "bing.com": .other, "duckduckgo.com": .other, "maps.google.com": .other,
        "photos.google.com": .other, "accounts.google.com": .other, "myaccount.google.com": .other,
    ]
}
