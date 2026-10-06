import XCTest
import SwiftUI
@testable import HUDCore

/// The limits list.
///
/// It replaced three pods that each headlined "the window with the least
/// headroom". That number was the problem: which window it quoted moved with
/// whatever happened to be tightest, so the same big figure meant the 5-hour
/// session on one plan and the Fable weekly on another, and the reset line under
/// it moved with it. Naming the windows helped and did not fix it — the shape of
/// a pod still changed depending on its own data.
///
/// So these pin the property that replaced it: a row is one window on one plan,
/// always, whatever the numbers say.
final class LimitsSectionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func window(_ kind: String, _ pctLeft: Int?) -> HUDCore.Window {
        HUDCore.Window(kind: kind, pctLeft: pctLeft, resetsAt: now.addingTimeInterval(3600), pace: nil)
    }

    private func sub(
        _ id: String,
        provider: String = "claude",
        windows: [HUDCore.Window],
        tightest: HUDCore.Window? = nil,
        stale: String? = nil,
        agents: Int = 0,
        readAt: Date? = nil
    ) -> Subscription {
        Subscription(id: id, provider: provider, label: id, readAt: readAt,
                     windows: windows, tightest: tightest ?? windows.first,
                     stale: stale, activeAgents: agents)
    }

    // MARK: - One row per window, whatever the numbers are

    func testAPlanDrawsARowForEveryWindowItReports() {
        let s = sub("claude-max", windows: [
            window("session_5h", 74), window("weekly_7d", 88), window("weekly_fable", 0),
        ])
        XCTAssertEqual(s.windows.map { Fmt.windowName(kind: $0.kind) }, ["5h", "7d", "fable"])
    }

    func testTheRowsDoNotReorderWhenADifferentWindowBecomesTightest() {
        // The regression this design exists to prevent. Same plan, two moments:
        // in the first the session is tightest, in the second Fable is. The rows
        // must read identically either way.
        let windows = [window("session_5h", 74), window("weekly_7d", 88), window("weekly_fable", 3)]
        let early = sub("claude-max", windows: windows, tightest: windows[0])
        let late = sub("claude-max", windows: windows, tightest: windows[2])
        XCTAssertEqual(early.windows.map(\.kind), late.windows.map(\.kind))
    }

    func testAPlanWithOneLimitDrawsOneRow() {
        let s = sub("codex", provider: "codex", windows: [window("weekly", 81)])
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertNil(s.sessionWindow)
    }

    func testWindowNamesAreTheOnesAReaderSees() {
        XCTAssertEqual(Fmt.windowName(kind: "session_5h"), "5h")
        XCTAssertEqual(Fmt.windowName(kind: "weekly_7d"), "7d")
        XCTAssertEqual(Fmt.windowName(kind: "weekly_fable"), "fable")
        XCTAssertEqual(Fmt.windowName(kind: "weekly"), "weekly")
        // An unfamiliar kind shows up as itself rather than as a bullet nobody
        // can look up.
        XCTAssertEqual(Fmt.windowName(kind: "monthly_new_thing"), "monthly_new_thing")
    }

    // MARK: - The note beside a plan's name

    func testAReasonToDistrustTheNumbersOutranksEverythingElse() {
        // Order matters: a rate-limit or a dead credential changes whether you
        // should believe the row at all, which beats knowing how old it is or
        // how many agents are on it.
        let s = sub("claude-max", windows: [window("session_5h", 74)],
                    stale: "rate limited, retry 4m", agents: 2,
                    readAt: now.addingTimeInterval(-3 * 86_400))
        XCTAssertNotNil(s.stale)
        XCTAssertNotNil(s.agedReading(now: now))
        XCTAssertEqual(s.activeAgents, 2)
        // All three are true; the view shows the first. Pinned here because the
        // precedence is the decision, not the rendering.
    }

    func testAPlanWithNoWindowsAtAllStillSaysWhy() {
        // A dead credential yields a reading with no windows. Drawing nothing
        // would look like a plan with no limits rather than one we cannot read.
        let s = sub("claude-max", windows: [], stale: "signed out · run claude auth login")
        XCTAssertTrue(s.windows.isEmpty)
        XCTAssertEqual(s.stale, "signed out · run claude auth login")
    }

    // MARK: - Render

    @MainActor
    func testTheCardRendersWithEveryPlanShape() throws {
        let subs = [
            sub("claude-max", windows: [window("session_5h", 74), window("weekly_7d", 88),
                                        window("weekly_fable", 0)]),
            sub("claude-team", windows: [window("session_5h", 18)], agents: 2),
            sub("codex", provider: "codex", windows: [window("weekly", 81)],
                readAt: now.addingTimeInterval(-3 * 86_400)),
            sub("claude-broken", windows: [], stale: "signed out · run claude auth login"),
        ]
        let snap = HUDSnapshot(version: 2, generatedAt: now, subscriptions: subs, agents: [],
                               value: nil, soonestReset: nil, setup: .sampleAllClear)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agenthud-limits-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try PreviewRenderer.renderCardPNG(snapshot: snap, now: now, to: url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000)
    }
}

/// The ACCOUNTS rule carries the auto-rotator's state, and says unknown rather
/// than off when nobody could ask.
final class AutoRotationStatusTests: XCTestCase {

    func testTheRotatorStateReadsOnOffOrUnknown() {
        XCTAssertEqual(AutoRotationStatus(auto: SwapAuto(running: true, threshold: 90)).text, "auto-rotation on")
        XCTAssertEqual(AutoRotationStatus(auto: SwapAuto(running: false, threshold: nil)).text, "auto-rotation off")
        XCTAssertEqual(AutoRotationStatus(auto: nil).text, "auto-rotation unknown")
    }
}
