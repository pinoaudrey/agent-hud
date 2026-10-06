import XCTest
import SwiftUI
@testable import HUDCore

/// Decoding the setup block, the states the panel has to distinguish, and the
/// clipboard payload.
///
/// The load-bearing property is that **absent never reads as healthy**. A green
/// panel that is really "we could not ask" is worse than no panel, so several of
/// these exist only to pin that distinction.
final class SetupTests: XCTestCase {

    private func snapshot(_ setupJSON: String) throws -> HUDSnapshot {
        let json = """
        {"version": 2, "generated_at": null, "subscriptions": [], "agents": [],
         "value": null, "soonest_reset": null, "setup": \(setupJSON)}
        """
        return try HUDSnapshot.decode(from: Data(json.utf8))
    }

    // MARK: - Decoding

    func testSetupBlockDecodes() throws {
        let snap = try snapshot("""
        {"version": 1, "generated_at": "2026-08-03T01:23:32+00:00", "problems": 2,
         "sections": [{"title": "every Claude account behaves the same",
                       "label": "accounts", "summary": "model", "status": "problem",
                       "results": [{"status": "problem", "message": "differs in: model",
                                    "fix": "pick one, then", "fix_command": "bin/capture.sh"}]}]}
        """)
        let setup = try XCTUnwrap(snap.setup)
        XCTAssertEqual(setup.problems, 2)
        XCTAssertFalse(setup.isClean)
        let section = try XCTUnwrap(setup.sections.first)
        XCTAssertEqual(section.label, "accounts")
        XCTAssertEqual(section.summary, "model")
        XCTAssertTrue(section.isProblem)
        XCTAssertEqual(section.problems.first?.fixCommand, "bin/capture.sh")
    }

    func testAV1SnapshotWithNoSetupKeyStillDecodes() throws {
        // A daemon that predates this work writes no `setup` key at all. The app
        // has to read that snapshot: the quota bars are still worth showing.
        let json = """
        {"version": 1, "generated_at": null, "subscriptions": [], "agents": [],
         "value": null, "soonest_reset": null}
        """
        let snap = try HUDSnapshot.decode(from: Data(json.utf8))
        XCTAssertNil(snap.setup)
    }

    func testANullSetupIsUnknownNotHealthy() throws {
        let snap = try snapshot("null")
        XCTAssertNil(snap.setup)
        // The distinction the whole feature rests on: nil is not a clean block.
        XCTAssertNotEqual(snap.setup?.isClean, true)
    }

    func testAnUnparseableSetupTimestampCostsOnlyTheTimestamp() throws {
        // The block crosses a repo boundary. A date shape this build cannot read
        // must not take the whole snapshot, and the quota bars, down with it.
        let snap = try snapshot("""
        {"version": 1, "generated_at": "last tuesday", "problems": 0, "sections": []}
        """)
        let setup = try XCTUnwrap(snap.setup)
        XCTAssertNil(setup.generatedAt)
        XCTAssertTrue(setup.isClean)
    }

    func testASectionMissingItsOptionalFieldsStillDecodes() throws {
        let snap = try snapshot("""
        {"version": 1, "problems": 0,
         "sections": [{"title": "a check", "status": "ok"}]}
        """)
        let section = try XCTUnwrap(snap.setup?.sections.first)
        XCTAssertEqual(section.label, "a check")  // the sentence stands in
        XCTAssertEqual(section.summary, "")
        XCTAssertEqual(section.results, [])
    }

    // MARK: - The menu-bar dot

    private func snapshotWith(setup: SetupBlock?) -> HUDSnapshot {
        HUDSnapshot(version: 2, generatedAt: nil, subscriptions: [], agents: [],
                    value: nil, soonestReset: nil, setup: setup)
    }

    func testTheMenuBarSaysNothingWhenTheSetupIsClean() {
        let view = MenuBarContentView(snapshot: snapshotWith(setup: .sampleAllClear))
        XCTAssertFalse(view.showsSetupDot)
    }

    func testTheMenuBarDotAppearsOnlyForRealProblems() {
        let view = MenuBarContentView(snapshot: snapshotWith(setup: .sampleWithProblems))
        XCTAssertTrue(view.showsSetupDot)
    }

    func testAnUncheckedSetupEarnsNoMenuBarDot() {
        // Unknown is not a problem to nag about, and a permanent dot for "we
        // could not ask" would train the eye to ignore the dot that matters.
        XCTAssertFalse(MenuBarContentView(snapshot: snapshotWith(setup: nil)).showsSetupDot)
        XCTAssertFalse(MenuBarContentView(snapshot: nil).showsSetupDot)
    }

    // MARK: - Clipboard

    func testClipboardPayloadNamesEveryProblemAndItsFix() {
        let text = SetupClipboard.payload(for: .sampleWithProblems)
        XCTAssertTrue(text.hasPrefix("My ~/.agents setup has 2 problems. Please fix them."))
        XCTAssertTrue(text.contains("1. every Claude account behaves the same"))
        XCTAssertTrue(text.contains(".claude-team differs from ~/.claude in: model"))
        XCTAssertTrue(text.contains("FIX      decide which is right, apply it to both, then bin/capture.sh"))
        XCTAssertTrue(text.contains("2. everything the manifest tracks is captured"))
    }

    func testClipboardPayloadCarriesTheRulesForFixingItProperly() {
        // Without these an agent will happily edit ~/.claude/CLAUDE.md directly,
        // which makes check-setup green and the setup worse.
        let text = SetupClipboard.payload(for: .sampleWithProblems)
        for rule in SetupClipboard.rules {
            XCTAssertTrue(text.contains(rule), "missing rule: \(rule)")
        }
    }

    func testClipboardPayloadOnlyListsProblems() {
        let text = SetupClipboard.payload(for: .sampleWithProblems)
        XCTAssertFalse(text.contains("Codex has a link for every skill"))
    }

    func testClipboardPayloadOnACleanMachineSaysSo() {
        XCTAssertEqual(SetupClipboard.payload(for: .sampleAllClear),
                       "My ~/.agents setup reports no problems.")
        XCTAssertEqual(SetupClipboard.payload(for: nil),
                       "My ~/.agents setup reports no problems.")
    }

    func testClipboardSingularReadsAsOneProblem() {
        let one = SetupBlock(version: 1, generatedAt: nil, problems: 1,
                             sections: [SetupSectionResult(
                                title: "the repo is committed and pushed", label: "pushed",
                                summary: "main", status: "problem",
                                results: [SetupResult(status: "problem",
                                                      message: "main is 2 commit(s) ahead of origin",
                                                      fix: "", fixCommand: "git push")])])
        let text = SetupClipboard.payload(for: one)
        XCTAssertTrue(text.contains("has 1 problem."))
        XCTAssertTrue(text.contains("FIX      git push"))
    }

    // MARK: - Render

    @MainActor
    func testTheCardRendersInAllThreeSetupStates() throws {
        for (name, setup) in [("problems", SetupBlock.sampleWithProblems),
                              ("clear", SetupBlock.sampleAllClear)] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("agenthud-setup-\(name)-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            let snap = HUDSnapshot(version: 2, generatedAt: HUDSnapshot.previewNow,
                                   subscriptions: HUDSnapshot.sample.subscriptions,
                                   agents: [], value: HUDSnapshot.sample.value,
                                   soonestReset: nil, setup: setup)
            try PreviewRenderer.renderCardPNG(snapshot: snap, to: url)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 1000, "\(name) rendered empty")
        }
        // Unknown is a distinct layout, so it gets its own pass.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agenthud-setup-unknown-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = HUDSnapshot(version: 2, generatedAt: HUDSnapshot.previewNow,
                               subscriptions: HUDSnapshot.sample.subscriptions,
                               agents: [], value: nil, soonestReset: nil, setup: nil)
        try PreviewRenderer.renderCardPNG(snapshot: snap, to: url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000)
    }
}

/// The fold over the passing checks: the problems stay open, the passing
/// checks fold behind one row, and the card is shorter for it.
final class SetupFoldTests: XCTestCase {

    private func section(_ title: String, problem: Bool) -> SetupSectionResult {
        SetupSectionResult(
            title: title, label: title, summary: problem ? "1 files" : "ok",
            status: problem ? "problem" : "ok",
            results: [SetupResult(status: problem ? "problem" : "ok", message: title,
                                  fix: problem ? "run it" : "", fixCommand: problem ? "bin/capture.sh" : "")])
    }

    private var sections: [SetupSectionResult] {
        (1...12).map { section("check \($0)", problem: false) } + [section("the machine is ahead", problem: true)]
    }

    @MainActor
    private func height(_ view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: 500))
        return renderer.cgImage.map { CGFloat($0.height) / renderer.scale } ?? 0
    }

    @MainActor
    func testThePassingChecksFoldAndTheCardIsShorter() {
        let folded = height(SetupProblemList(sections: sections))
        let open = height(SetupProblemList(sections: sections, showsPassing: true))
        XCTAssertGreaterThan(folded, 0)
        XCTAssertLessThan(folded * 2, open)
    }
}
