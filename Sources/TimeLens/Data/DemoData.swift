import Foundation
import TimeLensCore

/// Generated history for `--demo-data`, written to a separate database so every chart can be
/// checked without weeks of real use. Never touches the real data.
enum DemoData {
    private struct Choice {
        let app: String
        let site: String
        let weight: Double
        /// Mean minutes per stretch.
        let mean: Double
        let titles: [String]
    }

    private static let chrome = "com.google.Chrome"

    private static let choices: [Choice] = [
        Choice(app: "com.microsoft.VSCode", site: "", weight: 22, mean: 18, titles: ["SegmentBuilder.swift — time_tracker_macOS", "train.py — quad_move", "App.tsx — habit_tracker", "README.md — cf_perf"]),
        Choice(app: "com.mitchellh.ghostty", site: "", weight: 8, mean: 6, titles: ["swift build", "python train.py", "git status", "htop"]),
        Choice(app: chrome, site: "github.com", weight: 7, mean: 6, titles: ["apple/swift-collections", "Pull request #42", "Issues · mujoco"]),
        Choice(app: chrome, site: "youtube.com", weight: 9, mean: 14, titles: ["3Blue1Brown — Transformers explained", "Lo-fi beats to code to", "Codeforces Round editorial", "F1 highlights"]),
        Choice(app: chrome, site: "codeforces.com", weight: 6, mean: 20, titles: ["Problem 1923D", "Contest standings", "Blog entry"]),
        Choice(app: chrome, site: "leetcode.com", weight: 3, mean: 15, titles: ["Two Sum", "Daily challenge"]),
        Choice(app: chrome, site: "claude.ai", weight: 7, mean: 8, titles: ["New chat", "Swift concurrency question"]),
        Choice(app: chrome, site: "chatgpt.com", weight: 2, mean: 6, titles: ["ChatGPT"]),
        Choice(app: chrome, site: "reddit.com", weight: 4, mean: 7, titles: ["r/macapps", "r/MachineLearning"]),
        Choice(app: chrome, site: "x.com", weight: 3, mean: 5, titles: ["Home / X"]),
        Choice(app: chrome, site: "instagram.com", weight: 2, mean: 6, titles: ["Instagram"]),
        Choice(app: chrome, site: "wikipedia.org", weight: 2, mean: 5, titles: ["Kalman filter", "Linear programming"]),
        Choice(app: chrome, site: "docs.google.com", weight: 2, mean: 12, titles: ["Lab report", "Project notes"]),
        Choice(app: chrome, site: "mail.google.com", weight: 2, mean: 3, titles: ["Inbox"]),
        Choice(app: chrome, site: "netflix.com", weight: 1.5, mean: 35, titles: ["Netflix"]),
        Choice(app: chrome, site: SiteKey.privateSite, weight: 0.5, mean: 6, titles: []),
        Choice(app: "com.brave.Browser", site: "arxiv.org", weight: 2, mean: 12, titles: ["Attention Is All You Need", "PPO paper"]),
        Choice(app: "com.apple.Safari", site: "apple.com", weight: 0.7, mean: 4, titles: ["Apple"]),
        Choice(app: "org.mozilla.firefox", site: "kaggle.com", weight: 1, mean: 15, titles: ["Notebook"]),
        Choice(app: "net.whatsapp.WhatsApp", site: "", weight: 5, mean: 3, titles: ["WhatsApp"]),
        Choice(app: "com.hnc.Discord", site: "", weight: 3, mean: 6, titles: ["#general — SRA", "#cp-club"]),
        Choice(app: "com.tinyspeck.slackmacgap", site: "", weight: 1.5, mean: 4, titles: ["Slack"]),
        Choice(app: "md.obsidian", site: "", weight: 4, mean: 10, titles: ["Numerical Optimization", "Daily note"]),
        Choice(app: "notion.id", site: "", weight: 1.5, mean: 8, titles: ["Roadmap"]),
        Choice(app: "com.spotify.client", site: "", weight: 1.5, mean: 2, titles: ["Spotify"]),
        Choice(app: "com.figma.Desktop", site: "", weight: 1, mean: 14, titles: ["Portfolio redesign"]),
        Choice(app: "com.apple.finder", site: "", weight: 2, mean: 1.5, titles: ["Downloads"]),
        Choice(app: "com.apple.Preview", site: "", weight: 1.5, mean: 7, titles: ["ch3_simplex.pdf"]),
        Choice(app: "com.valvesoftware.steam", site: "", weight: 0.6, mean: 40, titles: ["Steam"]),
        Choice(app: "com.anthropic.claudefordesktop", site: "", weight: 2, mean: 7, titles: ["Claude"]),
    ]

    private static let names: [String: String] = [
        "com.microsoft.VSCode": "Visual Studio Code", "com.mitchellh.ghostty": "Ghostty", chrome: "Google Chrome",
        "com.brave.Browser": "Brave Browser", "com.apple.Safari": "Safari", "org.mozilla.firefox": "Firefox",
        "net.whatsapp.WhatsApp": "WhatsApp", "com.hnc.Discord": "Discord", "com.tinyspeck.slackmacgap": "Slack",
        "md.obsidian": "Obsidian", "notion.id": "Notion", "com.spotify.client": "Spotify", "com.figma.Desktop": "Figma",
        "com.apple.finder": "Finder", "com.apple.Preview": "Preview", "com.valvesoftware.steam": "Steam",
        "com.anthropic.claudefordesktop": "Claude",
    ]

    static func fill(_ store: ActivityStore, days: Int = 150) async {
        var generator = SeededGenerator(seed: 2211)
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        var usage: [UsageSegment] = []
        var details: [DetailSegment] = []
        var events: [EventRecord] = []
        var focus: [FocusRecord] = []
        var usageID: Int64 = 1
        var detailID: Int64 = 1
        let totalWeight = choices.reduce(0) { $0 + $1.weight }

        for (id, name) in names {
            store.saveApp(AppRecord(id: id, name: name, path: "", declaredCategory: ""))
        }

        for dayOffset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            // Some days off entirely.
            if Double.random(in: 0..<1, using: &generator) < 0.04 { continue }
            let wake = 8.0 + Double.random(in: 0..<2.5, using: &generator) + (weekend ? 1.5 : 0)
            let sleep = 23.0 + Double.random(in: 0..<2.8, using: &generator)
            var time = day.timeIntervalSince1970 + wake * 3600
            let end = min(day.timeIntervalSince1970 + sleep * 3600, now.timeIntervalSince1970)
            events.append(EventRecord(time: time, kind: .pickup, app: "", site: "", info: ""))

            // A focus session most weekdays.
            if !weekend, Double.random(in: 0..<1, using: &generator) < 0.6 {
                let start = time + Double.random(in: 3600..<14_400, using: &generator)
                if start < end {
                    let planned = [25.0, 50, 90].randomElement(using: &generator)! * 60
                    let completed = Double.random(in: 0..<1, using: &generator) < 0.75
                    let actual = completed ? planned : planned * Double.random(in: 0.2..<0.9, using: &generator)
                    focus.append(FocusRecord(id: 0, start: start, plannedEnd: start + planned, end: min(start + actual, end),
                                             completed: completed, blocked: Int.random(in: 0...4, using: &generator), label: ""))
                }
            }

            while time < end {
                // Breaks: short pauses often, longer ones (meals, classes) sometimes.
                let roll = Double.random(in: 0..<1, using: &generator)
                if roll < 0.10 {
                    let pause = Double.random(in: 900..<5400, using: &generator) * (weekend ? 1.4 : 1)
                    time += pause
                    events.append(EventRecord(time: time, kind: .pickup, app: "", site: "", info: ""))
                    continue
                } else if roll < 0.35 {
                    time += Double.random(in: 5..<180, using: &generator)
                }

                var pick = Double.random(in: 0..<totalWeight, using: &generator)
                var choice = choices[0]
                for candidate in choices {
                    // Weekends and late nights lean toward entertainment.
                    let hour = (time - day.timeIntervalSince1970) / 3600
                    var weight = candidate.weight
                    let category = Categorizer().category(app: candidate.app, site: candidate.site)
                    if weekend || hour >= 22, [.entertainment, .social, .games].contains(category) { weight *= 2.2 }
                    if weekend, category == .development { weight *= 0.6 }
                    pick -= weight
                    if pick <= 0 { choice = candidate; break }
                }
                let minutes = -log(max(Double.random(in: 0..<1, using: &generator), 0.001)) * choice.mean
                let length = min(max(minutes * 60, 4), 3 * 3600)
                let segmentEnd = min(time + length, end)
                let title = choice.titles.randomElement(using: &generator) ?? ""

                // Split at hour boundaries, as the tracker does.
                var cursor = time
                while cursor < segmentEnd {
                    let hourEnd = calendar.dateInterval(of: .hour, for: Date(timeIntervalSince1970: cursor))!.end.timeIntervalSince1970
                    let pieceEnd = min(hourEnd, segmentEnd)
                    usage.append(UsageSegment(id: usageID, start: cursor, end: pieceEnd, app: choice.app, site: choice.site))
                    usageID += 1
                    if !title.isEmpty {
                        let page = choice.site.isEmpty ? "" : "\(choice.site)/\(title.lowercased().replacingOccurrences(of: " ", with: "-").prefix(24))"
                        details.append(DetailSegment(id: detailID, start: cursor, end: pieceEnd, app: choice.app, site: choice.site, title: title, page: page))
                        detailID += 1
                    }
                    cursor = pieceEnd
                }
                time = segmentEnd
            }
        }
        await store.insertDemo(usage: usage, details: details, events: events, focus: focus)
    }
}

/// Deterministic randomness so the demo looks the same every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
