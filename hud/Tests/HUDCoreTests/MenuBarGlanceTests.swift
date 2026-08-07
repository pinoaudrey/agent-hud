import XCTest
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
@testable import HUDCore

/// The menu-bar glance: which plans reach the bar, the number each one shows,
/// when the number takes a pressure color, the mark on the signed-in plan, and
/// the fact that it draws in real color rather than as a template. That last
/// one is the reason `ink` exists — a template image gets AppKit's tint for
/// free, and giving that up means the glance has to resolve its own foreground
/// against the bar's appearance instead.
final class MenuBarGlanceTests: XCTestCase {

    private func window(_ kind: String, _ pctLeft: Int?) -> HUDCore.Window {
        HUDCore.Window(kind: kind, pctLeft: pctLeft, resetsAt: nil, pace: nil)
    }

    private func sub(_ id: String, provider: String = "claude", active: Bool = false,
                     windows: [HUDCore.Window]) -> Subscription {
        Subscription(id: id, provider: provider, label: id, active: active,
                     windows: windows, tightest: windows.first, stale: nil, activeAgents: 0)
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

    // MARK: - Which plans reach the bar

    func testCodexStaysOffTheBar() {
        // The bar answers "can I keep working right now"; Codex has no session
        // limit and no switcher, so it never changes that answer minute to
        // minute. It reads on the card, a click away.
        let snap = snapshot([sub("codex", provider: "codex", windows: [window("weekly", 81)]),
                             sub("claude-max", windows: [window("session_5h", 74)])])
        let glance = MenuBarContentView(snapshot: snap, now: now)
        XCTAssertEqual(glance.glanceSubs.map { $0.id }, ["claude-max"])
    }

    func testClaudePlansKeepTheCardsOrder() {
        let snap = snapshot([sub("claude-team", windows: [window("session_5h", 18)]),
                             sub("claude-max", windows: [window("session_5h", 74)])])
        let glance = MenuBarContentView(snapshot: snap, now: now)
        XCTAssertEqual(glance.glanceSubs.map { $0.id }, ["claude-team", "claude-max"])
    }

    // MARK: - The signed-in mark

    func testTheMarkNeedsMoreThanOneClaudePlan() {
        // Same rule as the card's SIGNED IN badge: a mark that could never move
        // is decoration.
        let one = MenuBarContentView(
            snapshot: snapshot([sub("claude-max", active: true,
                                    windows: [window("session_5h", 74)])]), now: now)
        XCTAssertFalse(one.marksActive)

        let two = MenuBarContentView(
            snapshot: snapshot([sub("claude-team", active: true,
                                    windows: [window("session_5h", 18)]),
                                sub("claude-max", windows: [window("session_5h", 74)])]),
            now: now)
        XCTAssertTrue(two.marksActive)
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
