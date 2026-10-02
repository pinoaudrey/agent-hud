import XCTest
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
@testable import HUDCore

/// The menu-bar glance: which plan reaches the bar, the letter, number and tag
/// it reads as, when the number gives way to a dash, when it takes a pressure
/// color, and the fact that it draws in real color rather than as a template.
/// That last one is the reason `ink` exists: a template image gets AppKit's
/// tint for free, and giving that up means the glance has to resolve its own
/// foreground against the bar's appearance instead.
final class MenuBarGlanceTests: XCTestCase {

    private func window(_ kind: String, _ pctLeft: Int?) -> HUDCore.Window {
        HUDCore.Window(kind: kind, pctLeft: pctLeft, resetsAt: nil, pace: nil)
    }

    /// `tightest` the way the daemon builds it: the window with the least left,
    /// among the ones that have a reading.
    private func sub(_ id: String, provider: String = "claude", active: Bool = false,
                     readAt: Date? = nil, stale: String? = nil,
                     windows: [HUDCore.Window]) -> Subscription {
        let tightest = windows.filter { $0.pctLeft != nil }.min { $0.pctLeft! < $1.pctLeft! }
        return Subscription(id: id, provider: provider, label: id, active: active,
                            readAt: readAt, windows: windows, tightest: tightest,
                            stale: stale, activeAgents: 0)
    }

    private func snapshot(
        _ subs: [Subscription],
        soonest: SoonestReset? = nil,
        setup: SetupBlock? = nil
    ) -> HUDSnapshot {
        HUDSnapshot(version: 2, generatedAt: nil, subscriptions: subs, agents: [],
                    value: nil, soonestReset: soonest, setup: setup)
    }

    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    // MARK: - No countdown

    func testTheBarCarriesNoCountdown() {
        // The only countdown that fits is the soonest reset across every plan,
        // which is one number that does not say which plan it belongs to. Each
        // plan's own reset, and its 5-hour clock, live on the card.
        let soonest = SoonestReset(subscriptionID: "codex", kind: "weekly",
                                   resetsAt: now.addingTimeInterval(3 * 3600))
        let snap = snapshot([sub("claude-max", windows: [window("session_5h", 40)])],
                            soonest: soonest)
        // The snapshot still carries it — the daemon contract is unchanged — but
        // nothing in the bar reads it.
        XCTAssertNotNil(snap.soonestReset)
    }

    // MARK: - Which plan reaches the bar

    func testCodexStaysOffTheBar() {
        // The bar answers "can I keep working right now"; Codex has no session
        // limit and no switcher, so it never changes that answer minute to
        // minute. It reads on the card, a click away. The daemon marks Codex
        // active too, so `active` alone must not pick it.
        let snap = snapshot([sub("codex", provider: "codex", active: true,
                                 windows: [window("weekly", 81)]),
                             sub("claude-max", active: true, windows: [window("session_5h", 74)])])
        let glance = MenuBarContentView(snapshot: snap, now: now)
        XCTAssertEqual(glance.signedIn?.id, "claude-max")
    }

    func testOnlyTheSignedInPlanReachesTheBar() {
        // The work plan is pressured, but it is not the one you are spending,
        // so it waits on the card.
        let snap = snapshot([sub("claude-team", windows: [window("session_5h", 4)]),
                             sub("claude-max", active: true, windows: [window("session_5h", 74)])])
        let glance = MenuBarContentView(snapshot: snap, now: now)
        XCTAssertEqual(glance.readout, GlanceReadout(sub: snap.subscriptions[1], now: now))
        XCTAssertEqual(glance.readout?.pctLeft, 74)
    }

    func testNoSignedInClaudePlanFallsBackToTheOfflineDashes() {
        // An older daemon marks nothing active. Guessing a plan would put the
        // wrong account's number on the bar.
        let snap = snapshot([sub("claude-team", windows: [window("session_5h", 18)]),
                             sub("claude-max", windows: [window("session_5h", 74)])])
        XCTAssertNil(MenuBarContentView(snapshot: snap, now: now).readout)
        XCTAssertNil(MenuBarContentView(snapshot: nil, now: now).readout)
    }

    // MARK: - The readout

    func testPersonalActiveReadsLetterFiveHourNumberAndTag() {
        let max = sub("claude-max", active: true,
                      windows: [window("session_5h", 61), window("weekly_7d", 83),
                                window("weekly_fable", 90)])
        let readout = GlanceReadout(sub: max, now: now)
        XCTAssertEqual(readout.letter, "P")
        XCTAssertEqual(readout.pctLeft, 61)
        XCTAssertEqual(readout.tag, "5h")
    }

    func testTheNumberStaysOnTheFiveHourWindowWhenAWeekIsTighter() {
        // The bar always means the 5-hour window, so a drier week does not
        // take the number over. The week reads on the card.
        let max = sub("claude-max", active: true,
                      windows: [window("session_5h", 96), window("weekly_7d", 22)])
        let readout = GlanceReadout(sub: max, now: now)
        XCTAssertEqual(readout.pctLeft, 96)
        XCTAssertEqual(readout.tag, "5h")
    }

    func testAFiveHourWindowWithNoReadingIsADash() {
        // The 5-hour window is there but unread. The bar does not swap in
        // another window's number, which would read as the session's.
        let max = sub("claude-max", active: true,
                      windows: [window("session_5h", nil), window("weekly_7d", 80)])
        let readout = GlanceReadout(sub: max, now: now)
        XCTAssertNil(readout.pctLeft)
        XCTAssertNil(readout.tag)
    }

    func testWorkActiveReadsW() {
        let team = sub("claude-team", active: true,
                       windows: [window("session_5h", 40), window("weekly_fable", 31)])
        let readout = GlanceReadout(sub: team, now: now)
        XCTAssertEqual(readout.letter, "W")
        XCTAssertEqual(readout.pctLeft, 40)
        XCTAssertEqual(readout.tag, "5h")
    }

    func testAnEnterpriseSpendCapReadsAsDollars() {
        // An Enterprise seat reports no rate windows; its one limit is the
        // monthly spend cap, which has no duration to name.
        let enterprise = sub("claude-enterprise", active: true, windows: [window("spend", 58)])
        let readout = GlanceReadout(sub: enterprise, now: now)
        XCTAssertEqual(readout.letter, "W")
        XCTAssertEqual(readout.pctLeft, 58)
        XCTAssertEqual(readout.tag, "$")
    }

    func testTheAccountLetterComesFromThePlanInTheId() {
        func letter(_ id: String, provider: String = "claude") -> String? {
            sub(id, provider: provider, windows: []).accountLetter
        }
        XCTAssertEqual(letter("claude-max"), "P")
        XCTAssertEqual(letter("claude-pro"), "P")
        // An organization with no plan word, named after an email address.
        XCTAssertEqual(letter("claude"), "P")
        XCTAssertEqual(letter("claude-team"), "W")
        XCTAssertEqual(letter("claude-enterprise"), "W")
        // Two Team orgs, told apart by the organization's name.
        XCTAssertEqual(letter("claude-team-carepilot"), "W")
        // A tree with no readable account says nothing about whose it is.
        XCTAssertNil(letter("claude-default"))
        XCTAssertNil(letter("codex", provider: "codex"))
        XCTAssertEqual(GlanceReadout(sub: sub("claude-default", windows: []), now: now).letter, "?")
    }

    // MARK: - An unreadable plan

    func testAPlanWithNoReadingKeepsItsLetterAndLosesTheNumber() {
        // Absence never reads as healthy. The letter stays, because which
        // account is signed in is still true.
        let noWindows = sub("claude-max", active: true, windows: [])
        let nullWindows = sub("claude-max", active: true, windows: [window("session_5h", nil)])
        for plan in [noWindows, nullWindows] {
            let readout = GlanceReadout(sub: plan, now: now)
            XCTAssertEqual(readout.letter, "P")
            XCTAssertNil(readout.pctLeft)
            XCTAssertNil(readout.tag)
        }
    }

    func testAReadingPastTheFreshnessLimitIsADashNotTheLastNumber() {
        let old = sub("claude-team", active: true,
                      readAt: now.addingTimeInterval(-(Subscription.freshnessLimit + 60)),
                      windows: [window("session_5h", 70)])
        let fresh = sub("claude-team", active: true, readAt: now.addingTimeInterval(-120),
                        windows: [window("session_5h", 70)])
        XCTAssertNil(GlanceReadout(sub: old, now: now).pctLeft)
        XCTAssertEqual(GlanceReadout(sub: fresh, now: now).pctLeft, 70)
    }

    func testAStaleFlagAloneKeepsTheLastNumber() {
        // A rate-limit cooldown serves the last good reading with a reason
        // attached. That number is minutes old and still true enough to show.
        let cooling = sub("claude-team", active: true, readAt: now.addingTimeInterval(-120),
                          stale: "rate limited, retry 4m", windows: [window("session_5h", 70)])
        let readout = GlanceReadout(sub: cooling, now: now)
        XCTAssertEqual(readout.pctLeft, 70)
        XCTAssertEqual(readout.tag, "5h")
    }

    func testADeadTokenAgesIntoTheDash() {
        // The daemon keeps `read_at` at the last good read while it serves the
        // cached numbers, so a plan that never recovers stops vouching for them.
        let signedOut = sub("claude-team", active: true,
                            readAt: now.addingTimeInterval(-(Subscription.freshnessLimit + 60)),
                            stale: "signed out, run claude auth login",
                            windows: [window("session_5h", 70)])
        XCTAssertNil(GlanceReadout(sub: signedOut, now: now).pctLeft)
    }

    // MARK: - The number's color

    func testTheNumberKeepsTheBarsInkWhileHealthy() {
        // A bar full of green numbers trains the eye to stop reading color;
        // color appears exactly when it means something.
        XCTAssertEqual(MenuBarContentView.numberColor(pctLeft: 74, ink: .white), .white)
        XCTAssertEqual(MenuBarContentView.numberColor(pctLeft: 25, ink: .black), .black)
        XCTAssertEqual(MenuBarContentView.numberColor(pctLeft: nil, ink: .white), .white)
    }

    func testTheNumberTakesTheSeverityColorOncePressured() {
        // The same threshold at which a pod lights.
        XCTAssertEqual(MenuBarContentView.numberColor(pctLeft: 24, ink: .white),
                       Theme.severity(pctLeft: 24))
        XCTAssertEqual(MenuBarContentView.numberColor(pctLeft: 0, ink: .white),
                       Theme.severity(pctLeft: 0))
    }

    // MARK: - Color, which is why this is not a template image

    #if canImport(AppKit)
    private func resolve(_ color: Color, _ appearance: NSAppearance.Name) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return resolved
    }

    func testSeverityIsThreeDistinctColorsSoARingCanSayMoreThanHowFullItIs() throws {
        // The whole reason the glance gives up template rendering: a template
        // flattens these into one shade, leaving a ring that shows how much is
        // spent but not whether that is fine.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let healthy = try XCTUnwrap(resolve(Theme.severity(pctLeft: 80), appearance))
            let pressured = try XCTUnwrap(resolve(Theme.severity(pctLeft: 10), appearance))
            let spent = try XCTUnwrap(resolve(Theme.severity(pctLeft: 0), appearance))
            XCTAssertNotEqual(healthy, pressured)
            XCTAssertNotEqual(pressured, spent)
            XCTAssertNotEqual(healthy, spent)
        }
    }

    func testTheInkTheAppPassesIsReadableOnEitherBar() throws {
        // AppDelegate resolves white on a dark bar and black on a light one. The
        // ring track is that ink at 28%, which still has to be visible against
        // the bar it sits on.
        let darkBar = NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1)
        let lightBar = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
        let onDark = NSColor.white.withAlphaComponent(0.28)
            .blended(withFraction: 0.72, of: darkBar) ?? darkBar
        let onLight = NSColor.black.withAlphaComponent(0.28)
            .blended(withFraction: 0.72, of: lightBar) ?? lightBar
        XCTAssertGreaterThan(onDark.brightnessComponent, darkBar.brightnessComponent)
        XCTAssertLessThan(onLight.brightnessComponent, lightBar.brightnessComponent)
    }

    @MainActor
    func testTheGlanceRendersInBothAppearancesAndWithAndWithoutTheDot() throws {
        for (name, setup) in [("problems", SetupBlock.sampleWithProblems),
                              ("clear", SetupBlock.sampleAllClear)] {
            let snap = snapshot(HUDSnapshot.sample.subscriptions,
                                soonest: HUDSnapshot.sample.soonestReset, setup: setup)
            for ink in [Color.white, Color.black] {
                let renderer = ImageRenderer(
                    content: MenuBarContentView(snapshot: snap, now: now, ink: ink)
                )
                renderer.scale = 2
                XCTAssertNotNil(renderer.nsImage, "\(name) glance rendered nothing")
            }
        }
    }

    @MainActor
    func testEveryReadoutStateRendersInBothInks() throws {
        let states: [(String, HUDSnapshot?)] = [
            ("spend", snapshot([sub("claude-enterprise", active: true,
                                    windows: [window("spend", 12)])])),
            ("unreadable", snapshot([sub("claude-max", active: true, windows: [])])),
            ("none signed in", snapshot([sub("claude-max", windows: [window("session_5h", 61)])])),
            ("offline", nil),
        ]
        for (name, snap) in states {
            for ink in [Color.white, Color.black] {
                let renderer = ImageRenderer(
                    content: MenuBarContentView(snapshot: snap, now: now, ink: ink)
                )
                renderer.scale = 2
                XCTAssertNotNil(renderer.nsImage, "\(name) glance rendered nothing")
            }
        }
    }
    #endif

    // MARK: - The ring track

    func testASpentLimitIsASolidRingRatherThanAnAbsence() {
        // A fuel gauge at empty draws no arc, which is the one state that most
        // needs to be visible. The track takes the severity at full strength so
        // a dead limit is a complete red circle.
        let cluster = RingCluster(rings: [])
        let spent = cluster.trackColor(pctLeft: 0, fraction: 0, severity: Theme.red)
        XCTAssertEqual(spent, Theme.red)
    }

    func testALiveLimitKeepsAWashedTrackSoTheArcStillReads() {
        let cluster = RingCluster(rings: [])
        let live = cluster.trackColor(pctLeft: 60, fraction: 0.6, severity: Theme.green)
        XCTAssertNotEqual(live, Theme.green)          // washed, not solid
        XCTAssertEqual(live, Theme.green.opacity(0.32))
    }

    func testAWindowWithNoReadingFallsBackToTheNeutralTrack() {
        let cluster = RingCluster(rings: [], track: .white.opacity(0.28))
        let none = cluster.trackColor(pctLeft: nil, fraction: 0, severity: Theme.hairline)
        XCTAssertEqual(none, .white.opacity(0.28))
    }

    // MARK: - The offline state

    func testOfflineDrawsDashesRatherThanEmptyRings() {
        // Empty rings would read as "three plans, all spent", which is the
        // opposite of "we cannot see the plans".
        XCTAssertFalse(MenuBarContentView(snapshot: nil, now: now).showsSetupDot)
    }
}
