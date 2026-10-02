import XCTest
import SwiftUI
@testable import HUDCore

/// Headless smoke test: the whole card view tree must lay out and rasterize
/// without crashing, in both appearances. Renders the sample snapshot to a temp
/// PNG and checks the file is a non-trivial image. The committed hud/preview.png
/// is generated the same way via `swift run agenthud-hud --render-preview`.
final class RenderTests: XCTestCase {

    private func assertNonEmptyPNG(at out: URL) throws {
        let data = try Data(contentsOf: out)
        XCTAssertGreaterThan(data.count, 2000, "rendered PNG suspiciously small")
        // PNG magic number.
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    @MainActor
    func testRendersCardToNonEmptyPNG() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("agenthud-hud-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }

        try PreviewRenderer.renderCardPNG(to: out, scale: 2, colorScheme: .dark)
        try assertNonEmptyPNG(at: out)
    }

    @MainActor
    func testRendersLightCardToNonEmptyPNG() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("agenthud-hud-light-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }

        try PreviewRenderer.renderCardPNG(to: out, scale: 2, colorScheme: .light)
        try assertNonEmptyPNG(at: out)
    }

    /// The sample has sessions blocked on you, so these carry the needs-you
    /// badge on the bar and the NEEDS YOU section on the card, in both inks.
    @MainActor
    func testRendersMenubarInBothInksToNonEmptyPNG() throws {
        for scheme in [ColorScheme.dark, .light] {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("agenthud-hud-menubar-test-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: out) }

            try PreviewRenderer.renderMenubarPNG(to: out, scale: 2, colorScheme: scheme)
            try assertNonEmptyPNG(at: out)
        }
    }
}
