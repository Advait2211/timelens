import Foundation
import Observation
import TimeLensCore

/// `Category` alone collides with the Objective-C runtime's `Category` type.
typealias UsageCategory = TimeLensCore.Category

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case time, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .time: "Today's screen time"
        case .icon: "Icon only"
        }
    }
}

/// Every setting, saved to UserDefaults as it changes.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // Tracking
    var idleMinutes: Double { didSet { defaults.set(idleMinutes, forKey: "idleMinutes") } }
    var honorMedia: Bool { didSet { defaults.set(honorMedia, forKey: "honorMedia") } }
    var privateMode: PrivateMode { didSet { defaults.set(privateMode.rawValue, forKey: "privateMode") } }
    var trackTitles: Bool { didSet { defaults.set(trackTitles, forKey: "trackTitles") } }
    var excludedApps: [String] { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    /// Keep window titles and pages for this many days (0 = forever). Time totals stay.
    var detailRetentionDays: Int { didSet { defaults.set(detailRetentionDays, forKey: "detailRetentionDays") } }

    // Display
    var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    /// Daily screen time goal in minutes (0 = none); drawn on charts.
    var dailyGoalMinutes: Int { didSet { defaults.set(dailyGoalMinutes, forKey: "dailyGoalMinutes") } }
    /// Calendar weekday weeks start on: 1 = Sunday, 2 = Monday.
    var weekStartsOn: Int { didSet { defaults.set(weekStartsOn, forKey: "weekStartsOn") } }

    // Breaks
    var breakReminders: Bool { didSet { defaults.set(breakReminders, forKey: "breakReminders") } }
    var breakIntervalMinutes: Int { didSet { defaults.set(breakIntervalMinutes, forKey: "breakIntervalMinutes") } }
    var breakLengthMinutes: Int { didSet { defaults.set(breakLengthMinutes, forKey: "breakLengthMinutes") } }
    var eyeReminders: Bool { didSet { defaults.set(eyeReminders, forKey: "eyeReminders") } }

    // Summaries
    var dailySummary: Bool { didSet { defaults.set(dailySummary, forKey: "dailySummary") } }
    var weeklySummary: Bool { didSet { defaults.set(weeklySummary, forKey: "weeklySummary") } }
    /// Minutes after midnight the daily summary goes out.
    var summaryMinute: Int { didSet { defaults.set(summaryMinute, forKey: "summaryMinute") } }
    /// Calendar weekday of the weekly report (1 = Sunday).
    var weeklySummaryDay: Int { didSet { defaults.set(weeklySummaryDay, forKey: "weeklySummaryDay") } }

    // Limits
    var limitWarnings: Bool { didSet { defaults.set(limitWarnings, forKey: "limitWarnings") } }

    // Focus
    var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: "focusMinutes") } }
    var focusBlockedCategories: [String] { didSet { defaults.set(focusBlockedCategories, forKey: "focusBlockedCategories") } }
    var focusBlockedApps: [String] { didSet { defaults.set(focusBlockedApps, forKey: "focusBlockedApps") } }
    var focusBlockedSites: [String] { didSet { defaults.set(focusBlockedSites, forKey: "focusBlockedSites") } }

    private init() {
        defaults.register(defaults: [
            "idleMinutes": 2.0,
            "honorMedia": true,
            "privateMode": PrivateMode.label.rawValue,
            "trackTitles": true,
            "detailRetentionDays": 0,
            "menuBarStyle": MenuBarStyle.time.rawValue,
            "dailyGoalMinutes": 0,
            "weekStartsOn": 2,
            "breakReminders": true,
            "breakIntervalMinutes": 50,
            "breakLengthMinutes": 5,
            "eyeReminders": false,
            "dailySummary": true,
            "weeklySummary": true,
            "summaryMinute": 21 * 60 + 30,
            "weeklySummaryDay": 1,
            "limitWarnings": true,
            "focusMinutes": 50,
            "focusBlockedCategories": [UsageCategory.social.rawValue, UsageCategory.entertainment.rawValue, UsageCategory.games.rawValue],
        ])
        idleMinutes = defaults.double(forKey: "idleMinutes")
        honorMedia = defaults.bool(forKey: "honorMedia")
        privateMode = PrivateMode(rawValue: defaults.string(forKey: "privateMode") ?? "") ?? .label
        trackTitles = defaults.bool(forKey: "trackTitles")
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []
        paused = defaults.bool(forKey: "paused")
        detailRetentionDays = defaults.integer(forKey: "detailRetentionDays")
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .time
        dailyGoalMinutes = defaults.integer(forKey: "dailyGoalMinutes")
        weekStartsOn = defaults.integer(forKey: "weekStartsOn")
        breakReminders = defaults.bool(forKey: "breakReminders")
        breakIntervalMinutes = defaults.integer(forKey: "breakIntervalMinutes")
        breakLengthMinutes = defaults.integer(forKey: "breakLengthMinutes")
        eyeReminders = defaults.bool(forKey: "eyeReminders")
        dailySummary = defaults.bool(forKey: "dailySummary")
        weeklySummary = defaults.bool(forKey: "weeklySummary")
        summaryMinute = defaults.integer(forKey: "summaryMinute")
        weeklySummaryDay = defaults.integer(forKey: "weeklySummaryDay")
        limitWarnings = defaults.bool(forKey: "limitWarnings")
        focusMinutes = defaults.integer(forKey: "focusMinutes")
        focusBlockedCategories = defaults.stringArray(forKey: "focusBlockedCategories") ?? []
        focusBlockedApps = defaults.stringArray(forKey: "focusBlockedApps") ?? []
        focusBlockedSites = defaults.stringArray(forKey: "focusBlockedSites") ?? []
    }

    var trackerSettings: TrackerSettings {
        TrackerSettings(
            idleThreshold: idleMinutes * 60,
            honorMedia: honorMedia,
            privateMode: privateMode,
            trackTitles: trackTitles,
            excluded: Set(excludedApps),
            paused: paused
        )
    }

    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartsOn
        return calendar
    }

    var dailyGoal: Double? { dailyGoalMinutes > 0 ? Double(dailyGoalMinutes) * 60 : nil }
}
