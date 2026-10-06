import Foundation

// Pure formatting helpers. Everything here is deterministic given an explicit
// `now`, so the unit tests can pin the clock and the views stay dumb.
public enum Fmt {

    /// Remaining fraction of a limit, in 0...1, from percent remaining.
    ///
    /// The one fill direction in this app: every bar and every ring reads as a
    /// fuel gauge, so a short bar or a bare ring always means little left. There
    /// used to be a `consumed` counterpart for the rings, which meant the same
    /// quantity ran in opposite directions in two places on one screen.
    ///
    /// A null reading is treated as empty.
    public static func remaining(pctLeft: Int?) -> Double {
        guard let pct = pctLeft else { return 0 }
        return Double(min(100, max(0, pct))) / 100.0
    }

    /// The bare percent-remaining glyph the glance shows, e.g. "18" or "--".
    /// No "%": the fuel bar beneath already reads it as a proportion.
    public static func glancePercent(pctLeft: Int?) -> String {
        pctLeft.map(String.init) ?? "--"
    }

    /// Wall-clock time like "11:47a" / "9:41a" used in status and pace lines.
    public static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        var s = f.string(from: date)
        s = s.replacingOccurrences(of: "AM", with: "a")
             .replacingOccurrences(of: "PM", with: "p")
        return s
    }

    /// The short glyph a meter row uses for a window kind.
    public static func windowLabel(kind: String) -> String {
        switch kind {
        case "session_5h":   return "5h"
        case "weekly_7d":    return "7d"
        case "weekly_fable": return "F"
        case "weekly":       return "7d"
        case "spend":        return "$"
        default:             return "•"
        }
    }

    /// The tag that follows the menu-bar number and says which window it is.
    /// The number is the plan's tightest window, which moves between windows as
    /// they drain and reset, so without the tag "61" could mean any of them.
    /// "wk" rather than "7d" because the bar has no other duration to set it
    /// against, and "$" for an Enterprise spend cap, which has no duration.
    public static func glanceTag(kind: String) -> String {
        switch kind {
        case "session_5h":            return "5h"
        case "weekly_7d", "weekly":   return "wk"
        case "weekly_fable":          return "fable"
        case "spend":                 return "$"
        default:                      return kind
        }
    }

    /// The name a pod's meter row uses. Longer than `windowLabel` because a pod
    /// row has space for it, and "fable" says which limit it is where "F" needs
    /// explaining. Codex's single window is called what it is: the plan has no
    /// session limit, so calling it "7d" would imply a second window exists.
    public static func windowName(kind: String) -> String {
        switch kind {
        case "session_5h":   return "5h"
        case "weekly_7d":    return "7d"
        case "weekly_fable": return "fable"
        case "weekly":       return "weekly"
        case "spend":        return "spend"
        default:             return kind
        }
    }

    /// "Tue 4:00p" — a day and a clock time, for a reset far enough out that a
    /// countdown says less than a weekday does. Today's resets drop the day.
    public static func dayClock(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return clock(date)
        }
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return "\(f.string(from: date)) \(clock(date))"
    }

    /// Rough time since something happened, for a footer: "12s ago", "4m ago".
    /// A future timestamp (clock skew between the daemon and the app) reads as
    /// "just now" rather than as a negative age.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// How long a session has waited on you, for a NEEDS YOU row: "<1m",
    /// "12m", "1h 05m", "2d 3h". Minutes at the finest, because the card only
    /// redraws every half minute and a seconds count would read as frozen.
    public static func waited(since date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date))) / 60
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(String(format: "%02d", minutes % 60))m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// Time-in-state for an agent row, e.g. "1m12" / "44s" / "2h06".
    public static func sinceLabel(seconds: Int?) -> String {
        guard let s = seconds, s >= 0 else { return "" }
        if s < 60 { return "\(s)s" }
        let minutes = s / 60
        if minutes < 60 {
            let secs = s - minutes * 60
            return "\(minutes)m\(String(format: "%02d", secs))"
        }
        let hours = s / 3600
        let mins = (s - hours * 3600) / 60
        return "\(hours)h\(String(format: "%02d", mins))"
    }
}
