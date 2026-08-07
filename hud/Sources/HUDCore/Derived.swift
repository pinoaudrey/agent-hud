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

    /// The single window the menu-bar glance headlines: the 5h session, i.e.
    /// the immediate "can I work right now" budget. Falls back to the tightest
    /// window, then the first, so every subscription resolves to one number.
    /// A dry weekly/Fable limit is not surfaced here by design; it reads in the
    /// popover a click away, where every window is shown.
    public var glanceWindow: Window? {
        sessionWindow ?? tightest ?? windows.first
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

    public var waitingAgentCount: Int {
        agents.filter { $0.isWaiting }.count
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
