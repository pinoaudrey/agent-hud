import SwiftUI

/// The menu-bar status-item content: how much the signed-in Claude plan has
/// left, and a single dot when the agent setup has problems.
///
/// The bar speaks for one plan, the one a bare `claude` would spend right now,
/// because that is the only budget the work in front of you draws on. It reads
/// as a letter, a number and a tag, `P 61 5h`: which account (P for a plan you
/// hold yourself, W for a seat at work), the percent left in that plan's
/// 5-hour session window, and the tag that names it. The number is always the
/// 5-hour window, so it means the same thing at every glance. A plan with no
/// 5-hour window (an Enterprise seat, whose one limit is the spend cap) shows
/// its tightest window instead, and the tag says which. Every other plan, and
/// every other window, reads on the card a click away.
///
/// Codex is deliberately absent. The bar answers "can I keep working right
/// now", and with no switcher and no session limit, Codex never changes that
/// answer minute to minute; its quota reads on the card, a click away.
///
/// There is no countdown: the only one that fits is the soonest reset across
/// every plan, which is a single number that does not say which plan it
/// belongs to.
///
/// The glance is **not** rendered as a template image: a template throws its
/// pixels away and takes AppKit's tint, which is what keeps a monochrome icon
/// legible over any wallpaper but would also flatten the pressure colors into
/// one shade. So it draws in real color, and everything that is *not* severity
/// resolves against the menu bar's own appearance instead, which is what `ink`
/// carries (see AppDelegate, which re-renders whenever that appearance changes).
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

    /// The one plan the bar speaks for: the signed-in Claude plan. Nil when
    /// the daemon is offline, or names no Claude plan as signed in.
    public var signedIn: Subscription? {
        snapshot?.subscriptions.first { $0.provider == "claude" && $0.active }
    }

    /// What the bar draws for the signed-in plan, or nil for the offline dashes.
    public var readout: GlanceReadout? {
        signedIn.map { GlanceReadout(sub: $0, now: now) }
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
            if needsYouCount > 0 {
                NeedsYouBadge(count: needsYouCount)
            }
            if let readout {
                GlanceReadoutView(readout: readout, ink: ink)
            } else {
                // Offline, or no Claude plan signed in. Dashes, not zeros: "we
                // cannot see the plans" must not read as "spent".
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

    /// Sessions blocked on you. Leftmost on the bar, and absent at zero.
    public var needsYouCount: Int {
        snapshot?.waitingAgentCount ?? 0
    }

    /// True only for real problems. A setup the daemon could not check shows
    /// nothing: an unanswered question is not worth a permanent mark, and a dot
    /// that is always there trains the eye to stop seeing it.
    public var showsSetupDot: Bool {
        guard let setup = snapshot?.setup else { return false }
        return !setup.isClean
    }
}

/// The signed-in plan as the bar reads it: the account letter, and the 5-hour
/// window's percent left (or the tightest window's, for a plan with no 5-hour
/// window) with the tag that names that window. A plan
/// whose numbers cannot be trusted keeps its letter and loses the number, so
/// the bar still says which account is signed in without vouching for it.
public struct GlanceReadout: Equatable {
    /// "P" or "W", or "?" when the subscription id does not say which.
    public let letter: String
    /// Nil when the plan is unreadable: no window with a reading, or a reading
    /// older than the card's freshness limit. A `stale` flag alone keeps the
    /// number. The daemon sets it whenever it serves its last good reading (a
    /// rate-limit cooldown, a dead token), and `readAt` stays the time of that
    /// read, so a plan that cannot recover still ages into the dash.
    public let pctLeft: Int?
    /// "5h", "wk", "fable" or "$". Nil exactly when `pctLeft` is.
    public let tag: String?

    public init(sub: Subscription, now: Date) {
        letter = sub.accountLetter ?? "?"
        let fresh = sub.agedReading(now: now) == nil
        if fresh, let window = sub.sessionWindow ?? sub.tightest, let pct = window.pctLeft {
            pctLeft = pct
            tag = Fmt.glanceTag(kind: window.kind)
        } else {
            pctLeft = nil
            tag = nil
        }
    }
}

/// `P 61 5h`. Only the number takes a pressure color. The letter and the tag
/// are labels, so they stay in the bar's ink and step back from the number;
/// which account is signed in is never a reason to color anything.
struct GlanceReadoutView: View {
    let readout: GlanceReadout
    let ink: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(readout.letter)
                .font(Theme.mono(12, weight: .semibold))
                .foregroundStyle(ink.opacity(0.6))
            if let pct = readout.pctLeft, let tag = readout.tag {
                // The bare number, "61". No "%": the tag already says what the
                // number counts, and the glyph costs width on every glance.
                Text(Fmt.glancePercent(pctLeft: pct))
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(MenuBarContentView.numberColor(pctLeft: pct, ink: ink))
                    .monospacedDigit()
                Text(tag)
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(ink.opacity(0.6))
            } else {
                // A dash, not a zero and not the last number: absence must not
                // read as healthy, and it must not read as spent either.
                Text("–")
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.35))
                    .accessibilityLabel("no reading")
            }
        }
        .fixedSize()
    }
}
