import SwiftUI

// #1461: the one status-pill idiom, the way OVCapsuleButton (#1451) is the one small-button idiom. About
// twenty badges across the app each hand-drew their own `Capsule().fill(tint.opacity(...))`, and with
// nothing forcing their opacities, paddings and fonts to agree they had drifted (0.10, 0.12, 0.14, 0.15,
// 0.16 all in use for the same semantic). A pill is a translucent tinted capsule around a short label, and
// its meaning is carried by ONE of four tones, not by a colour a caller picks by eye.
//
// Only the translucent status pills belong here. A SOLID capsule (Keep, Restore, Confirm) is a button, not
// a pill, and lives on OVCapsuleButton or its own Button; the non-pill capsules (the search field, the
// agent-status dot, a progress fill) are shapes that happen to be capsules, not badges.
enum OVPillTone {
    case warning     // rust: a problem, a caution, a "no"
    case pending     // gold: waiting on something, a soft maybe
    // #1628: dim gold. Found something, but cannot stand behind it. Deliberately the same HUE as
    // `pending` rather than a new signal colour, so it reads as a quieter member of the found-something
    // family. It exists because the four tones above had no slot between "act on this" and "nothing
    // here": `confirmed` is nominally that slot and is unusable on the dark forest background, which is
    // what made "Email found" the faintest badge on the card until #1645. Dan reached it after rejecting
    // rust for this state: "unverified email looks like no email, too similar."
    //
    // NOTE the tone names describe SEMANTICS while these badges are now assigned by PRIORITY (how much
    // Dan would act on the row). #1646 tracks reconciling the vocabulary; until then, read the assignment
    // at the call site rather than trusting the name here.
    case tentative
    case confirmed   // forest: done, found, a "yes"
    case neutral     // ink: a fact that is neither good nor bad (e.g. "went by")

    var tint: Color {
        switch self {
        case .warning: return OVColor.rust
        case .pending: return OVColor.gold
        case .tentative: return OVColor.goldDim
        case .confirmed: return OVColor.forest
        case .neutral: return OVColor.inkFaint
        }
    }

    // One opacity for every tone, so the same semantic can never read at two strengths in two rows again.
    // The value the majority of sites already used before this consolidation, so most pills do not move.
    static let fillOpacity: Double = 0.12
}

extension View {
    // Apply the shared status-pill chrome (font, tone colour, padding, translucent capsule) to a label.
    // The label can be plain `Text` or an `HStack` of an icon and text; everything else a site wants (a
    // `.help`, a `.padding(.top,)`, being the label of a Menu or Button) stays at the call site, so this
    // owns only what every pill shares and nothing a pill varies.
    func ovPill(_ tone: OVPillTone) -> some View {
        self
            .font(OVType.tag)
            .foregroundStyle(tone.tint)
            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 5)
            .background(Capsule().fill(tone.tint.opacity(OVPillTone.fillOpacity)))
    }
}
