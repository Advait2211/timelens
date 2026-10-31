import Testing
@testable import TimeLensCore

@Suite struct SiteKeyTests {
    @Test func stripsSchemeQueryAndPrefixes() {
        let parsed = SiteKey.parse("https://www.github.com/apple/swift/?tab=readme#top")
        #expect(parsed?.site == "github.com")
        #expect(parsed?.host == "github.com")
        #expect(parsed?.page == "github.com/apple/swift")
    }

    @Test func addressBarTextWithoutScheme() {
        #expect(SiteKey.parse("github.com/foo")?.site == "github.com")
        #expect(SiteKey.parse("m.youtube.com/watch")?.site == "youtube.com")
    }

    @Test func registrableDomain() {
        #expect(SiteKey.parse("https://en.wikipedia.org/wiki/Swift")?.site == "wikipedia.org")
        #expect(SiteKey.parse("https://docs.python.org/3/")?.site == "python.org")
        #expect(SiteKey.parse("https://www.bbc.co.uk/news")?.site == "bbc.co.uk")
        #expect(SiteKey.parse("https://vjti.ac.in")?.site == "vjti.ac.in")
        #expect(SiteKey.parse("https://portal.vjti.ac.in/x")?.site == "vjti.ac.in")
    }

    @Test func productSubdomainsStayApart() {
        #expect(SiteKey.parse("https://mail.google.com/mail/u/0/#inbox")?.site == "mail.google.com")
        #expect(SiteKey.parse("https://docs.google.com/document/d/1")?.site == "docs.google.com")
        #expect(SiteKey.parse("https://music.youtube.com/")?.site == "music.youtube.com")
        #expect(SiteKey.parse("https://www.youtube.com/watch?v=1")?.site == "youtube.com")
        #expect(SiteKey.parse("https://advait2211.github.io/")?.site == "advait2211.github.io")
        #expect(SiteKey.parse("https://drama-tracker-eta.vercel.app/")?.site == "drama-tracker-eta.vercel.app")
    }

    @Test func localServersKeepTheirPort() {
        #expect(SiteKey.parse("http://localhost:3000/dashboard")?.site == "localhost:3000")
        #expect(SiteKey.parse("http://127.0.0.1:8000")?.site == "127.0.0.1:8000")
    }

    @Test func browserPagesAndFiles() {
        #expect(SiteKey.parse("chrome://newtab/")?.site == SiteKey.browserPages)
        #expect(SiteKey.parse("about:blank")?.site == SiteKey.browserPages)
        #expect(SiteKey.parse("brave://settings")?.site == SiteKey.browserPages)
        #expect(SiteKey.parse("file:///Users/x/a.pdf")?.site == SiteKey.localFiles)
    }

    @Test func junkIsRejected() {
        #expect(SiteKey.parse("") == nil)
        #expect(SiteKey.parse("missing value") == nil)
        #expect(SiteKey.parse("search terms here") == nil)
    }

    @Test func titleCleaning() {
        #expect(TitleCleaner.clean("(3) YouTube") == "YouTube")
        #expect(TitleCleaner.clean("Inbox - Google Chrome") == "Inbox")
        #expect(TitleCleaner.clean("   ") == nil)
    }
}

@Suite struct CategorizerTests {
    @Test func builtInTablesLoad() {
        // Dictionary literals with duplicate keys trap on first use.
        #expect(!Categorizer.apps.isEmpty)
        #expect(!Categorizer.sites.isEmpty)
        #expect(!Categorizer.declaredMapping.isEmpty)
    }

    @Test func sitesDecideForBrowsers() {
        let categorizer = Categorizer()
        #expect(categorizer.category(app: "com.google.Chrome", site: "youtube.com") == .entertainment)
        #expect(categorizer.category(app: "com.google.Chrome", site: "codeforces.com") == .development)
        #expect(categorizer.category(app: "com.google.Chrome", site: "docs.python.org") == .development)
        #expect(categorizer.category(app: "com.google.Chrome", site: SiteKey.privateSite) == .other)
        #expect(categorizer.category(app: "com.microsoft.VSCode", site: "") == .development)
        #expect(categorizer.category(app: "com.jetbrains.pycharm", site: "") == .development)
    }

    @Test func declaredCategoryFallback() {
        let categorizer = Categorizer(declaredCategories: ["com.example.game": "public.app-category.puzzle-games"])
        #expect(categorizer.appCategory("com.example.game") == .games)
        #expect(categorizer.appCategory("com.example.unknown") == .other)
    }

    @Test func overridesWin() {
        var categorizer = Categorizer()
        categorizer.overrides[Override.siteKey("youtube.com")] = Override(category: .learning)
        categorizer.overrides[Override.categoryKey(.social)] = Override(rating: .neutral)
        #expect(categorizer.category(app: "com.google.Chrome", site: "youtube.com") == .learning)
        #expect(categorizer.rating(app: "com.google.Chrome", site: "youtube.com") == .productive)
        #expect(categorizer.rating(app: "com.google.Chrome", site: "reddit.com") == .neutral)
    }
}
