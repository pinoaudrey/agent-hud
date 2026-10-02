import SwiftUI

// View-facing derivations over the raw contract structs. Kept out of the views
// so they can be unit tested and so the rendering code stays declarative.

extension Window {
    public var isSession: Bool { kind == "session_5h" }
    public var isWeekly: Bool { kind.hasPrefix("weekly") }
    public var isFable: Bool { kind == "weekly_fable" }
    public var isLimitReached: Bool { (pctLeft ?? 100) <= 0 }
}

extension Subscription {
    /// Outer ring source: the 5h session window.
    public var sessionWindow: Window? {
        windows.first { $0.isSession }
    }

    /// Inner ring source: the first weekly window (7d, or Fable for that sub).
    public var weeklyWindow: Window? {
        windows.first { $0.isWeekly }
    }

    /// The plain weekly window (Claude `weekly_7d`, Codex `weekly`), never Fable.
    public var weekly7dWindow: Window? {
        windows.first { $0.isWeekly && !$0.isFable }
    }

    /// The model-scoped Fable weekly window, if this subscription has one.
    public var fableWindow: Window? {
        windows.first { $0.isFable }
    }

    /// Which of your accounts this is, as one letter for the menu bar: "P" for
    /// a plan you hold yourself, "W" for a seat your employer holds. Nil when
    /// the id does not say, which the bar shows as "?" rather than guessing.
    ///
    /// Read from the id because the daemon names a subscription after its
    /// organization type (`claude-max`, `claude-enterprise`), and a disambiguated
    /// id only appends to that (`claude-team-carepilot`). A bare `claude` is an
    /// organization with no plan word that is named after an email address,
    /// which is what an individual account looks like.
    public var accountLetter: String? {
        guard provider == "claude" else { return nil }
        if id == "claude" { return "P" }
        guard id.hasPrefix("claude-") else { return nil }
        let plan = id.dropFirst("claude-".count).split(separator: "-").first ?? ""
        switch plan {
        case "max", "pro", "free":     return "P"
        case "team", "enterprise":     return "W"
        default:                       return nil
        }
    }

    /// How old a reading is allowed to be before the pod says so. Claude is
    /// re-read every three minutes, so anything past this means something is
    /// wrong — a cooldown, a dead daemon, a machine just back from sleep — or,
    /// for Codex, simply that you have not run it lately.
    public static let freshnessLimit: TimeInterval = 10 * 60

    /// The reading's age when it is old enough to be worth saying, else nil.
    ///
    /// Codex has no API to ask: its numbers come out of a rollout file written as
    /// a side effect of a turn, so they are exactly as old as your last Codex
    /// turn. A weekly window that has since reset makes an old percentage wrong,
    /// not merely late, which is why this is surfaced rather than smoothed over.
    public func agedReading(now: Date) -> Date? {
        guard let readAt, now.timeIntervalSince(readAt) > Self.freshnessLimit else { return nil }
        return readAt
    }

    public var isIdle: Bool { activeAgents <= 0 }

    public var hasLimitReached: Bool {
        windows.contains { $0.isLimitReached }
    }

    /// Cluster opacity: full when working, dim when idle, but a spent limit
    /// stays bright enough for the red to still read.
    public var clusterOpacity: Double {
        if hasLimitReached { return 0.55 }
        return isIdle ? 0.4 : 1.0
    }

    /// The right-aligned status string for the section header and its color.
    public func status(now: Date = Date()) -> (text: String, color: Color) {
        if hasLimitReached {
            return ("limit reached", Theme.red)
        }
        if let tight = tightest, let pct = tight.pctLeft, pct < 25 {
            if let reset = tight.resetsAt {
                let label = Fmt.windowLabel(kind: tight.kind)
                return ("\(label) resets \(Fmt.clock(reset))", Theme.amber)
            }
            return ("pressured", Theme.amber)
        }
        return ("healthy", Theme.green)
    }
}

extension Agent {
    public var isWaiting: Bool { state == "waiting" }
    public var isWorking: Bool { state == "working" }
    public var isIdle: Bool { !isWaiting && !isWorking }
    /// A Claude Desktop app session, which has no terminal to raise.
    public var isDesktop: Bool { surface == "desktop" }

    /// The row name: the daemon's title, else the directory, else the tool, so
    /// a row is never blank.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return project.isEmpty ? tool : project
    }
}

/// The NEEDS YOU section's two groups.
///
/// Blocked is every session waiting on you, longest wait first: the one that
/// has sat stopped the longest has cost the most. Finished is every session
/// that went idle in the last two hours, newest first: the work you have not
/// looked at yet. Past two hours a finished session is history, not a prompt.
public struct NeedsYou: Equatable {
    public let blocked: [Agent]
    public let finished: [Agent]

    public static let finishedWindow: TimeInterval = 2 * 3600

    public var isEmpty: Bool { blocked.isEmpty && finished.isEmpty }

    public init(agents: [Agent], now: Date) {
        blocked = agents
            .filter { $0.isWaiting }
            .sorted { a, b in
                // A wait with no start time (an older daemon) sorts last rather
                // than claiming to be the longest.
                let (x, y) = (a.stateSince ?? .distantFuture, b.stateSince ?? .distantFuture)
                return x != y ? x < y : a.pid < b.pid
            }
        finished = agents
            .filter { agent in
                guard agent.state == "idle", let since = agent.stateSince else { return false }
                return now.timeIntervalSince(since) <= Self.finishedWindow
            }
            .sorted { a, b in
                let (x, y) = (a.stateSince ?? .distantPast, b.stateSince ?? .distantPast)
                return x != y ? x > y : a.pid < b.pid
            }
    }
}

extension HUDSnapshot {
    /// The subscriptions in presentation order: every Claude plan first, in the
    /// order the daemon discovered them (the default config tree leads), then
    /// Codex. Deliberately not a hardcoded list of ids — ids now come from
    /// whichever organizations this machine is signed into, so a fixed list
    /// would silently drop any subscription it had not been told about.
    public var orderedSubscriptions: [Subscription] {
        subscriptions.filter { $0.provider != "codex" } + subscriptions.filter { $0.provider == "codex" }
    }

    /// How many sessions are blocked on you: the menu bar's needs-you count.
    public var waitingAgentCount: Int {
        agents.filter { $0.isWaiting }.count
    }

    public func needsYou(now: Date) -> NeedsYou {
        NeedsYou(agents: agents, now: now)
    }

    /// Agents that count as live: currently working or waiting. Idle and stale
    /// sessions are dropped, so a count built on this can't go out of date.
    public var runningAgents: [Agent] {
        agents.filter { !$0.isIdle }
    }

    /// The single tightest window across every subscription, spent limits
    /// included: the one number that answers "is anything about to run out".
    public var worstWindow: Window? {
        subscriptions
            .compactMap { $0.tightest }
            .min { ($0.pctLeft ?? 101) < ($1.pctLeft ?? 101) }
    }
}
