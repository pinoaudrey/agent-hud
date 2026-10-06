import XCTest
@testable import HUDCore

/// The needs-you notifications: which polls alert, which take a notice down,
/// and what one says. Nothing is posted here; the app delegate posts.
final class NeedsYouAlertsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func agent(_ pid: Int, _ state: String, minutesAgo: Int? = 1,
                       action: String? = "input needed", surface: String? = "terminal") -> Agent {
        Agent(pid: pid, tool: "claude", project: "web-app", cwd: "/x/web-app", state: state,
              action: action, sinceSeconds: nil, subscriptionID: nil,
              title: "session \(pid)", surface: surface,
              stateSince: minutesAgo.map { now.addingTimeInterval(TimeInterval(-$0 * 60)) })
    }

    private func snapshot(_ agents: [Agent]) -> HUDSnapshot {
        HUDSnapshot(version: 4, generatedAt: now, subscriptions: [], agents: agents,
                    value: nil, soonestReset: nil)
    }

    func testTheFirstSnapshotSeedsWithoutAlerting() {
        var alerts = NeedsYouAlerts()
        let change = alerts.update(with: snapshot([agent(1, "waiting")]))
        XCTAssertEqual(change, NeedsYouAlerts.Change(arrived: [], ended: []))
    }

    func testANewWaitAlertsOnceAcrossPolls() {
        var alerts = NeedsYouAlerts()
        _ = alerts.update(with: snapshot([agent(1, "working")]))
        let blocked = snapshot([agent(1, "waiting")])

        XCTAssertEqual(alerts.update(with: blocked).arrived.map(\.pid), [1])
        XCTAssertEqual(alerts.update(with: blocked).arrived, [])
    }

    func testFinishedAndWorkingSessionsNeverAlert() {
        var alerts = NeedsYouAlerts()
        _ = alerts.update(with: snapshot([]))
        let change = alerts.update(with: snapshot([agent(1, "idle"), agent(2, "working")]))
        XCTAssertEqual(change.arrived, [])
    }

    func testAnEndedWaitTakesItsNoticeDown() {
        var alerts = NeedsYouAlerts()
        _ = alerts.update(with: snapshot([]))
        let waiting = agent(1, "waiting")
        _ = alerts.update(with: snapshot([waiting]))

        let change = alerts.update(with: snapshot([agent(1, "working")]))
        XCTAssertEqual(change.ended, [NeedsYouAlerts.identifier(for: waiting)])
    }

    func testASecondWaitOfTheSameSessionAlertsAgain() {
        var alerts = NeedsYouAlerts()
        _ = alerts.update(with: snapshot([]))
        _ = alerts.update(with: snapshot([agent(1, "waiting", minutesAgo: 10)]))
        _ = alerts.update(with: snapshot([agent(1, "working")]))

        XCTAssertEqual(alerts.update(with: snapshot([agent(1, "waiting", minutesAgo: 1)])).arrived.map(\.pid), [1])
    }

    func testAPollWithNoSnapshotKeepsTheWaitsItKnows() {
        var alerts = NeedsYouAlerts()
        _ = alerts.update(with: snapshot([]))
        _ = alerts.update(with: snapshot([agent(1, "waiting")]))

        XCTAssertEqual(alerts.update(with: nil), NeedsYouAlerts.Change(arrived: [], ended: []))
        XCTAssertEqual(alerts.update(with: snapshot([agent(1, "waiting")])).arrived, [])
    }

    func testSeveralArrivalsComeLongestWaitFirst() {
        var alerts = NeedsYouAlerts()
        _ = alerts.update(with: snapshot([]))
        let change = alerts.update(with: snapshot([agent(1, "waiting", minutesAgo: 2), agent(2, "waiting", minutesAgo: 5)]))
        XCTAssertEqual(change.arrived.map(\.pid), [2, 1])
    }

    func testTheNoticeNamesTheSessionTheAskAndWhereItRuns() {
        let terminal = NeedsYouNotice(agent: agent(7, "waiting", action: "permission needed"))
        XCTAssertEqual(terminal.title, "session 7 needs you")
        XCTAssertEqual(terminal.body, "Permission needed · web-app in Terminal")
        XCTAssertEqual(terminal.pid, 7)

        let desktop = NeedsYouNotice(agent: agent(8, "waiting", action: nil, surface: "desktop"))
        XCTAssertEqual(desktop.body, "Waiting · web-app in Claude app")
    }
}
