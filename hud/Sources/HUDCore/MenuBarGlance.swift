import SwiftUI

/// The menu-bar status-item content: each Claude plan's 5-hour headroom as a
/// number, a mark on the signed-in plan, and a single dot when the agent setup
/// has problems.
///
/// Codex is deliberately absent. The bar answers "can I keep working right
/// now", and with no switcher and no session limit, Codex never changes that
/// answer minute to minute; its quota reads on the card, a click away.
///
/// The number is the 5-hour window because that is the immediate budget — the
/// weekly limits move too slowly to be worth a permanent spot in the bar, and
/// they read on the card with their resets. There is likewise no countdown: the
/// only one that fits is the soonest reset across every plan, which is a single
/// number that does not say which plan it belongs to.
///
/// The glance is **not** rendered as a template image: a template throws its
/// pixels away and takes AppKit's tint, which is what keeps a monochrome icon
/// legible over any wallpaper but would also flatten the pressure colors into
/// one shade. So it draws in real color, and everything that is *not* severity
/// resolves against the menu bar's own appearance instead, which is what `ink`
/// carries — see AppDelegate, which re-renders whenever that appearance changes.
public struct MenuBarContentView: View {
    public let snapshot: HUDSnapshot?
    public var now: Date
    /// The menu bar's own foreground colour, resolved from its current
    /// appearance: near-white on a dark bar, near-black on a light one. Used
    /// for healthy numbers and the offline dashes, never for a pressure state.
    public var ink: Color

    public init(snapshot: HUDSnapshot?, now: Date = Date(), ink: Color = .primary) {
        self.snapshot = snapshot
        self.now = now
        self.ink = ink
    }

    /// The plans the bar shows: Claude only, in the card's order.
    public var glanceSubs: [Subscription] {
        (snapshot?.orderedSubscriptions ?? []).filter { $0.provider == "claude" }
    }

    /// Same rule as the card's SIGNED IN badge: with a single Claude plan the
    /// mark could never move, and a mark that never moves is decoration.
    public var marksActive: Bool {
        glanceSubs.count > 1
    }

    /// Ink while the plan is healthy, the severity color once the window is
    /// pressured (under 25% left) or spent — the same threshold at which a pod
    /// lights. A bar full of green numbers would train the eye to stop reading
    /// color at all; color appears exactly when it means something.
    public static func numberColor(pctLeft: Int?, ink: Color) -> Color {
        guard let pct = pctLeft, pct < 25 else { return ink }
        return Theme.severity(pctLeft: pct)
    }

    public var body: some View {
        HStack(spacing: 8) {
            if !glanceSubs.isEmpty {
                ForEach(glanceSubs) { sub in
                    GlanceNumber(
                        pctLeft: sub.glanceWindow?.pctLeft,
                        marked: marksActive && sub.active,
                        ink: ink
                    )
                }
            } else {
                // Offline, or a machine with no Claude plan at all. Dashes, not
                // zeros: "we cannot see the plans" must not read as "spent".
                ForEach(0..<2, id: \.self) { _ in
                    Text("–")
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.35))
                }
            }
            if showsSetupDot {
                // One dot, and nothing at all when the setup is clean. The menu
                // bar is where you are not looking, so it may say "come look" and
                // nothing more; the count and the detail are one click away. A
                // setup the daemon could not check shows nothing either: an
                // unanswered question is not worth a permanent mark.
                Circle()
                    .fill(Theme.amber)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("agent setup has problems")
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        // ImageRenderer can propose the glance less than its ideal width in the
        // status-item context, which turns "74" into "7…". The glance is never
        // legitimately compressible, so it always takes its ideal size.
        .fixedSize()
    }

    /// True only for real problems. A setup the daemon could not check shows
    /// nothing: an unanswered question is not worth a permanent mark, and a dot
    /// that is always there trains the eye to stop seeing it.
    public var showsSetupDot: Bool {
        guard let setup = snapshot?.setup else { return false }
        return !setup.isClean
    }
}

/// One plan's number: the 5-hour percent left, with a coral mark when this is
/// the signed-in plan. The mark leads the number so the marked figure reads as
/// one unit rather than a number with trailing punctuation.
struct GlanceNumber: View {
    let pctLeft: Int?
    let marked: Bool
    let ink: Color

    var body: some View {
        HStack(spacing: 3) {
            if marked {
                Circle()
                    .fill(Theme.claudeCoral)
                    .frame(width: 4, height: 4)
                    .accessibilityLabel("signed in")
            }
            Text(text)
                .font(Theme.mono(12, weight: .semibold))
                .foregroundStyle(MenuBarContentView.numberColor(pctLeft: pctLeft, ink: ink))
                .monospacedDigit()
                .fixedSize()
        }
    }

    /// The bare number, "74". No "%": with only numbers on the bar there is
    /// nothing else it could mean, and the glyph costs width on every glance.
    /// A window with no reading is a dash, not a zero.
    private var text: String {
        pctLeft != nil ? Fmt.glancePercent(pctLeft: pctLeft) : "–"
    }
}
