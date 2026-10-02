import XCTest
import SwiftUI
@testable import HUDCore

final class FormattingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func plus(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    // MARK: Countdown ladder

    // MARK: Remaining fraction (every bar and ring)

    func testRemainingFractionMatchesItsNumber() {
        // Everything fills by what's LEFT: a full ring or bar means plenty.
        XCTAssertEqual(Fmt.remaining(pctLeft: 100), 1.0, accuracy: 0.0001)
        XCTAssertEqual(Fmt.remaining(pctLeft: 74), 0.74, accuracy: 0.0001)
        XCTAssertEqual(Fmt.remaining(pctLeft: 18), 0.18, accuracy: 0.0001)
        XCTAssertEqual(Fmt.remaining(pctLeft: 0), 0.0, accuracy: 0.0001)
    }

    func testRemainingFractionClampsAndHandlesNull() {
        XCTAssertEqual(Fmt.remaining(pctLeft: nil), 0.0, accuracy: 0.0001)
        XCTAssertEqual(Fmt.remaining(pctLeft: 150), 1.0, accuracy: 0.0001)
        XCTAssertEqual(Fmt.remaining(pctLeft: -20), 0.0, accuracy: 0.0001)
    }

    func testGlancePercentGlyph() {
        XCTAssertEqual(Fmt.glancePercent(pctLeft: 18), "18")
        XCTAssertEqual(Fmt.glancePercent(pctLeft: 0), "0")
        XCTAssertEqual(Fmt.glancePercent(pctLeft: nil), "--")
    }

    // MARK: Severity color mapping

    func testSeverityMapping() {
        XCTAssertEqual(Theme.severity(pctLeft: 80), Theme.green)
        XCTAssertEqual(Theme.severity(pctLeft: 25), Theme.green) // boundary: <25 is amber, 25 is green
        XCTAssertEqual(Theme.severity(pctLeft: 24), Theme.amber)
        XCTAssertEqual(Theme.severity(pctLeft: 1), Theme.amber)
        XCTAssertEqual(Theme.severity(pctLeft: 0), Theme.red)
        XCTAssertEqual(Theme.severity(pctLeft: nil), Theme.hairline)
    }

    // MARK: Meter value + window labels

    func testWindowLabels() {
        XCTAssertEqual(Fmt.windowLabel(kind: "session_5h"), "5h")
        XCTAssertEqual(Fmt.windowLabel(kind: "weekly_7d"), "7d")
        XCTAssertEqual(Fmt.windowLabel(kind: "weekly_fable"), "F")
        XCTAssertEqual(Fmt.windowLabel(kind: "weekly"), "7d")
        XCTAssertEqual(Fmt.windowLabel(kind: "spend"), "$")
        XCTAssertEqual(Fmt.windowName(kind: "spend"), "spend")
    }

    func testGlanceTags() {
        XCTAssertEqual(Fmt.glanceTag(kind: "session_5h"), "5h")
        XCTAssertEqual(Fmt.glanceTag(kind: "weekly_7d"), "wk")
        XCTAssertEqual(Fmt.glanceTag(kind: "weekly"), "wk")
        XCTAssertEqual(Fmt.glanceTag(kind: "weekly_fable"), "fable")
        XCTAssertEqual(Fmt.glanceTag(kind: "spend"), "$")
    }

    // MARK: Value formatting

    func testUSDFormatting() {
        XCTAssertEqual(Fmt.usd(182), "$182")
        XCTAssertEqual(Fmt.usd(3140), "$3.1k")
        XCTAssertEqual(Fmt.usd(0), "$0")
    }

    func testMultipleFormatting() {
        XCTAssertEqual(Fmt.multiple(12.6), "12.6×")
    }

    func testSinceLabel() {
        XCTAssertEqual(Fmt.sinceLabel(seconds: 44), "44s")
        XCTAssertEqual(Fmt.sinceLabel(seconds: 72), "1m12")
        XCTAssertEqual(Fmt.sinceLabel(seconds: 3 * 3600 + 5 * 60), "3h05")
        XCTAssertEqual(Fmt.sinceLabel(seconds: nil), "")
    }

    // MARK: Cluster opacity derivations

    func testClusterOpacity() {
        let working = Subscription(id: "a", provider: "claude", label: "A",
            windows: [Window(kind: "session_5h", pctLeft: 50, resetsAt: nil, pace: nil)],
            tightest: nil, stale: nil, activeAgents: 2)
        XCTAssertEqual(working.clusterOpacity, 1.0, accuracy: 0.001)

        let idle = Subscription(id: "b", provider: "claude", label: "B",
            windows: [Window(kind: "session_5h", pctLeft: 50, resetsAt: nil, pace: nil)],
            tightest: nil, stale: nil, activeAgents: 0)
        XCTAssertEqual(idle.clusterOpacity, 0.4, accuracy: 0.001)

        let spent = Subscription(id: "c", provider: "claude", label: "C",
            windows: [Window(kind: "session_5h", pctLeft: 0, resetsAt: nil, pace: nil)],
            tightest: nil, stale: nil, activeAgents: 0)
        XCTAssertEqual(spent.clusterOpacity, 0.55, accuracy: 0.001)
    }
}
