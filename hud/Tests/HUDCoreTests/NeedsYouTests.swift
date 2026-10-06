import XCTest
import SwiftUI
@testable import HUDCore

/// NEEDS YOU: decoding the v4 agent fields (and still decoding v3, which has
/// none), which sessions land in Blocked and Finished and in what order, the
/// menu-bar count that is absent at zero, and what a row click would do. The
/// click itself is never run here: nothing on the machine moves in a test.
final class NeedsYouTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func agent(_ pid: Int, _ state: String, tool: String = "claude",
                       minutesAgo: Int?, surface: String? = "terminal",
                       tty: String? = nil, hostSessionID: String? = nil) -> Agent {
        Agent(pid: pid, tool: tool, project: "p\(pid)", cwd: "/tmp/p\(pid)", state: state,
              action: state == "waiting" ? "input needed" : nil, sinceSeconds: nil,
              subscriptionID: nil, title: "session \(pid)", surface: surface, tty: tty,
              hostSessionID: hostSessionID,
              stateSince: minutesAgo.map { now.addingTimeInterval(TimeInterval(-$0 * 60)) })
    }

    private func snapshot(_ agents: [Agent]) -> HUDSnapshot {
        HUDSnapshot(version: 4, generatedAt: now, subscriptions: [], agents: agents,
                    value: nil, soonestReset: nil)
    }

    // MARK: - Decoding

    func testV4AgentFieldsDecode() throws {
        let json = #"""
        {"version":4,"generated_at":"2026-10-02T19:51:34.242000+00:00","subscriptions":[],
         "value":null,"soonest_reset":null,
         "agents":[{"pid":6877,"tool":"claude","project":"web-app","cwd":"/x/web-app",
                    "state":"waiting","action":"input needed","since_seconds":600,
                    "subscription_id":"claude-max","session_id":"8d466826",
                    "title":"Hold intake sections","surface":"desktop","tty":null,
                    "host_session_id":"local_24dad477","state_since":"2026-10-02T19:28:53.935000+00:00"}]}
        """#
        let agent = try XCTUnwrap(HUDSnapshot.decode(from: Data(json.utf8)).agents.first)
        XCTAssertEqual(agent.sessionID, "8d466826")
        XCTAssertEqual(agent.title, "Hold intake sections")
        XCTAssertTrue(agent.isDesktop)
        XCTAssertNil(agent.tty)
        XCTAssertEqual(agent.hostSessionID, "local_24dad477")
        let since = try XCTUnwrap(agent.stateSince)
        XCTAssertEqual(since.timeIntervalSince1970, 1_790_969_333.935, accuracy: 0.001)
    }

    func testV3AgentStillDecodesAndNeverNeedsYou() throws {
        let json = #"""
        {"version":3,"generated_at":"2026-08-07T13:41:00Z","subscriptions":[],
         "value":null,"soonest_reset":null,
         "agents":[{"pid":1,"tool":"claude","project":"web-app","cwd":"/x/web-app",
                    "state":"idle","action":null,"since_seconds":60,"subscription_id":null}]}
        """#
        let snap = try HUDSnapshot.decode(from: Data(json.utf8))
        let agent = try XCTUnwrap(snap.agents.first)
        XCTAssertNil(agent.title)
        XCTAssertNil(agent.stateSince)
        XCTAssertFalse(agent.isDesktop)  // no surface reads as terminal
        XCTAssertEqual(agent.displayTitle, "web-app")
        XCTAssertTrue(snap.needsYou(now: now).isEmpty)
    }

    // MARK: - Grouping and order

    func testBlockedIsLongestWaitFirst() {
        let snap = snapshot([
            agent(1, "waiting", minutesAgo: 3),
            agent(2, "waiting", minutesAgo: 40),
            agent(3, "waiting", minutesAgo: nil),  // no start time: last, not longest
            agent(4, "working", minutesAgo: 90),
        ])
        XCTAssertEqual(snap.needsYou(now: now).blocked.map(\.pid), [2, 1, 3])
    }

    func testFinishedIsIdleWithinTwoHoursNewestFirst() {
        let snap = snapshot([
            agent(1, "idle", minutesAgo: 47),
            agent(2, "idle", minutesAgo: 12),
            agent(3, "idle", minutesAgo: 121),     // past the window
            agent(4, "idle", tool: "codex", minutesAgo: nil),  // no finish time to judge
            agent(5, "working", minutesAgo: 5),
            agent(6, "waiting", minutesAgo: 5),
        ])
        let needsYou = snap.needsYou(now: now)
        XCTAssertEqual(needsYou.finished.map(\.pid), [2, 1])
        XCTAssertEqual(needsYou.blocked.map(\.pid), [6])
    }

    func testNothingWaitingOrRecentlyFinishedHidesTheSection() {
        let snap = snapshot([agent(1, "working", minutesAgo: 5), agent(2, "idle", minutesAgo: 300)])
        XCTAssertTrue(snap.needsYou(now: now).isEmpty)
    }

    func testSampleShowsBothGroups() {
        let needsYou = HUDSnapshot.sample.needsYou(now: HUDSnapshot.previewNow)
        XCTAssertEqual(needsYou.blocked.count, 2)
        XCTAssertEqual(needsYou.finished.count, 2)
    }

    // MARK: - Menu bar count

    func testBadgeCountsWaitingSessionsAndIsAbsentAtZero() {
        let busy = snapshot([agent(1, "working", minutesAgo: 1), agent(2, "idle", minutesAgo: 1)])
        XCTAssertEqual(MenuBarContentView(snapshot: busy, now: now).needsYouCount, 0)
        XCTAssertEqual(MenuBarContentView(snapshot: nil, now: now).needsYouCount, 0)

        let blocked = snapshot([agent(1, "waiting", minutesAgo: 1), agent(2, "waiting", minutesAgo: 9)])
        XCTAssertEqual(MenuBarContentView(snapshot: blocked, now: now).needsYouCount, 2)
    }

    @MainActor
    func testBarIsNarrowerWithoutTheBadge() {
        func width(_ snap: HUDSnapshot) -> CGFloat {
            let renderer = ImageRenderer(content: MenuBarContentView(snapshot: snap, now: now, ink: .white))
            return renderer.cgImage.map { CGFloat($0.width) } ?? 0
        }
        let quiet = snapshot([agent(1, "working", minutesAgo: 1)])
        let waiting = snapshot([agent(1, "waiting", minutesAgo: 1)])
        XCTAssertGreaterThan(width(waiting), width(quiet))
    }

    // MARK: - Bringing a session forward

    func testTerminalRowSelectsTheTabByDevice() {
        let action = SessionFocus.action(for: agent(1, "waiting", minutesAgo: 1, tty: "ttys012"))
        XCTAssertEqual(action, .terminalTab(device: "/dev/ttys012"))
        XCTAssertTrue(SessionFocus.terminalScript(device: "/dev/ttys012")
            .contains(#"if tty of t is "/dev/ttys012" then"#))
    }

    func testTerminalRowWithoutASafeTTYDoesNothing() {
        XCTAssertEqual(SessionFocus.action(for: agent(1, "waiting", minutesAgo: 1, tty: nil)), .none)
        // Interpolated into a script, so anything but the `ps` shape is refused.
        let hostile = agent(1, "waiting", minutesAgo: 1, tty: #"ttys1" then activate"#)
        XCTAssertEqual(SessionFocus.action(for: hostile), .none)
    }

    func testDesktopRowOpensTheSessionLinkOrFallsBackToActivation() {
        let linked = agent(1, "waiting", minutesAgo: 1, surface: "desktop",
                           hostSessionID: "local_24dad477-a055-41a0-83fb-295c5b937828")
        XCTAssertEqual(SessionFocus.action(for: linked),
                       .claudeLink(URL(string: "claude://code/continue?session=local_24dad477-a055-41a0-83fb-295c5b937828")!))

        let unlinked = agent(2, "idle", minutesAgo: 1, surface: "desktop")
        XCTAssertEqual(SessionFocus.action(for: unlinked), .activateClaude)
        let odd = agent(3, "idle", minutesAgo: 1, surface: "desktop", hostSessionID: "local_x&evil=1")
        XCTAssertEqual(SessionFocus.action(for: odd), .activateClaude)
    }

    // MARK: - Formatting

    func testWaitedReadsInMinutesAndUp() {
        func waited(_ seconds: Int) -> String {
            Fmt.waited(since: now.addingTimeInterval(TimeInterval(-seconds)), now: now)
        }
        XCTAssertEqual(waited(20), "<1m")
        XCTAssertEqual(waited(14 * 60 + 30), "14m")
        XCTAssertEqual(waited(65 * 60), "1h 05m")
        XCTAssertEqual(waited(26 * 3600), "1d 2h")
        XCTAssertEqual(waited(-30), "<1m")  // clock skew is not a negative wait
    }
}

/// Which NEEDS YOU rows get the hover wash and the hand cursor: only the rows a
/// click can act on.
final class NeedsYouClickableTests: XCTestCase {

    private func agent(tty: String?, surface: String = "terminal") -> Agent {
        Agent(pid: 1, tool: "claude", project: "p", cwd: "/p", state: "waiting", action: nil,
              sinceSeconds: nil, subscriptionID: nil, surface: surface, tty: tty)
    }

    private func section(onSelect: ((Agent) -> Void)?) -> NeedsYouSection {
        NeedsYouSection(needsYou: NeedsYou(agents: [], now: Date()), now: Date(), onSelect: onSelect)
    }

    func testARowWithSomewhereToGoIsClickable() {
        let live = section(onSelect: { _ in })
        XCTAssertTrue(live.isClickable(agent(tty: "ttys012")))
        XCTAssertTrue(live.isClickable(agent(tty: nil, surface: "desktop")))
    }

    func testARowWithNowhereToGoIsNot() {
        XCTAssertFalse(section(onSelect: { _ in }).isClickable(agent(tty: nil)))
        XCTAssertFalse(section(onSelect: nil).isClickable(agent(tty: "ttys012")))
    }
}
