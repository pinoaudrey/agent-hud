import SwiftUI

// The account-rotation panel: cswap's side of the story. The LIMITS section
// already badges the signed-in plan (from what `~/.claude` holds), so this
// section carries what the pods cannot: the cswap slot aliases those plans
// answer to ("work", "personal"), and whether the auto-rotator is alive and
// what threshold it switches at. The active row says "signed in" — the same
// words as the badge — because the two are one fact reported through two
// paths, and a card that names one state two ways invents a distinction.
//
// Rendered only when the daemon has a swap block. A machine without cswap, or
// a daemon that could not ask, sends null, and an unmanaged machine should not
// carry an empty panel about a tool it does not run.

public struct SwapSection: View {
    public let swap: SwapBlock
    /// The snapshot's subscriptions, used to name each account the way its pod
    /// does ("Claude Team") rather than by email.
    public let subs: [Subscription]

    public init(swap: SwapBlock, subs: [Subscription]) {
        self.swap = swap
        self.subs = subs
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionRule(title: "ACCOUNT ROTATION") { autoStatus }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(swap.accounts) { account in
                    SwapRow(account: account, planLabel: planLabel(for: account))
                }
            }
            .padding(.horizontal, 3)
        }
    }

    private func planLabel(for account: SwapAccount) -> String? {
        guard let id = account.subscriptionID else { return nil }
        return subs.first { $0.id == id }?.label
    }

    /// The rotator's state lives in the header, mirroring how the setup rule
    /// carries its verdict. `nil` renders as unknown, never as "off": a rotator
    /// we could not ask about might be switching accounts right now.
    @ViewBuilder
    private var autoStatus: some View {
        if let auto = swap.auto {
            if auto.running, let threshold = auto.threshold {
                statusText("auto-switch at \(threshold)%", color: Theme.green)
            } else if auto.running {
                statusText("auto-switch on", color: Theme.green)
            } else {
                statusText("auto-switch off", color: Theme.amber)
            }
        } else {
            statusText("auto-switch unknown", color: Theme.muted)
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.label(11))
            .tracking(0.4)
            .foregroundStyle(color)
            .fixedSize()
    }
}

/// One managed account: its cswap name, the plan its organization maps to on
/// this machine, and whether it is the one holding `~/.claude`. The active row
/// draws at full contrast; standby rows recede, the same figure/ground rule the
/// pods use for their windows.
struct SwapRow: View {
    let account: SwapAccount
    let planLabel: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.active ? Theme.claudeCoral : Theme.faint)
                .frame(width: 7, height: 7)
            Text(account.displayName)
                .font(Theme.label(12))
                .foregroundStyle(account.active ? Theme.text : Theme.faint)
            if let planLabel {
                Text(planLabel)
                    .font(Theme.label(12))
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 8)
            Text(account.active ? "signed in" : "standby")
                .font(Theme.label(11))
                .foregroundStyle(account.active ? Theme.text : Theme.faint)
        }
    }
}
