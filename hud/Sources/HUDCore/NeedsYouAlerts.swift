import Foundation

/// Which NEEDS YOU sessions deserve a macOS notification, poll to poll.
///
/// Only Blocked sessions alert: a session waiting on you costs time every
/// minute it waits, while a finished one can wait for the next glance at the
/// card. A wait is keyed by its pid and the moment it started, so a session
/// that waits, resumes, and waits again alerts twice, and one that stays
/// blocked across many polls alerts once.
///
/// The first snapshot seeds the tracker without alerting: launching the app
/// must not replay every wait that was already on screen. A poll with no
/// snapshot (the daemon down, no cache) changes nothing, so a wait that
/// survives an outage does not alert again when the daemon comes back.
public struct NeedsYouAlerts {

    public struct Change: Equatable {
        /// Sessions that started waiting since the last poll, oldest wait first.
        public let arrived: [Agent]
        /// Notification ids of waits that have ended, to take down.
        public let ended: [String]
    }

    private var waiting: Set<String>?

    public init() {}

    public static func identifier(for agent: Agent) -> String {
        let since = agent.stateSince.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return "needs-you-\(agent.pid)-\(since)"
    }

    public mutating func update(with snapshot: HUDSnapshot?) -> Change {
        guard let snapshot else { return Change(arrived: [], ended: []) }
        let blocked = snapshot.needsYou(now: snapshot.generatedAt ?? Date()).blocked
        let current = Set(blocked.map(Self.identifier(for:)))
        defer { waiting = current }
        guard let previous = waiting else { return Change(arrived: [], ended: []) }
        return Change(
            arrived: blocked.filter { !previous.contains(Self.identifier(for: $0)) },
            ended: previous.subtracting(current).sorted()
        )
    }
}

/// The words on one needs-you notification.
public struct NeedsYouNotice: Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    public let pid: Int

    public init(agent: Agent) {
        identifier = NeedsYouAlerts.identifier(for: agent)
        title = "\(agent.displayTitle) needs you"
        let action = agent.action.flatMap { $0.isEmpty ? nil : $0 } ?? "waiting"
        let place = agent.isDesktop ? "Claude app" : "Terminal"
        body = [action.prefix(1).uppercased() + action.dropFirst(), "\(agent.project) in \(place)"]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        pid = agent.pid
    }
}
