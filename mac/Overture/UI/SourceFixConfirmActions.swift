import SwiftUI
import SwiftData

// #1027: the inline FIX (correct the URL) and CONFIRM (this page is right, stop nagging) controls for a
// failing source. ONE component, used in both the end-of-scout popup and the durable Sources sheet, so
// the two surfaces cannot drift into offering different actions or wording.
//
// FIX is offered wherever a wrong address could be the cause (failure.offersFix). CONFIRM is offered
// only on a page that read fine but was empty (failure.offersConfirm). Neither is gated on
// hasUnreadChanges: a no_dated_content failure always leaves that flag set, so gating on it would
// disable CONFIRM in the exact case it is meant for. confirmEmpty anchors to the bytes last read, and
// the ingest match is exact, so a stale confirmation can only fail to suppress (a harmless re-nag),
// never suppress the wrong page.
//
// #1048: in the Sources sheet that re-nag is invisible and confusing, because a source's last read can
// be OLD (a watch-only pass saw the page change but never re-read). So when the read is stale
// (WatchedSource.confirmReadIsStale) CONFIRM is still offered, but a gold hint says it will not stick
// until the page is read again. The popup path is always fresh, so the hint never appears there.
struct SourceFixConfirmActions: View {
    let source: WatchedSource
    // #1177: optional, because the editor is now offered on EVERY active, editable source row, not only a
    // failed one. The Cell reads fine but is empty (no failure), and its real shows are on another host: a
    // wrong address is exactly what it might have, so a healthy row must still be re-pointable. When there
    // is no failure, Fix is offered (a wrong address is plausible) and Confirm is not (there is no
    // empty-page failure to confirm). The two existing callers pass a non-nil failure, so they are
    // unchanged.
    let failure: SourceFailure?
    // Called with the source id when Dan saves a corrected URL, so the popup can read the ones he fixed.
    var onFixed: (String) -> Void = { _ in }
    // #1426: whether this surface also offers to stop watching the source. OFF by default, and the Sources
    // sheet leaves it off, because every active row there already carries its own Stop watching button:
    // defaulting it on would put two identical buttons on the same row. The scout results popup turns it
    // on, where the failing source is named in front of Dan and his only alternative is to close the popup
    // and find that same row in the sheet. Same removal (WatchlistMutations.stopWatching), same banner,
    // same Undo: this is a second PLACE to take the action, never a second way to take it.
    var offersStopWatching: Bool = false
    // #2207: this page read FINE and came back with nothing, on a source that has listed shows before.
    // That is not a recorded failure (nothing failed), and it is exactly the state Confirm settles: "yes,
    // this page is right, it is just quiet". Passed in rather than inferred, because the fact lives in the
    // run's results and not on the row: by the time the row is read, a silently empty source and a
    // genuinely healthy one are indistinguishable.
    var readFineAndCameBackEmpty: Bool = false

    // #1177: whether each control is offered, decided here (not in the body) so a test can pin the default
    // for a healthy row. Fix defaults on (a wrong address is plausible on any editable source); Confirm
    // defaults off (nothing to confirm without an empty-page failure). With a failure, its own predicates
    // win, so the failing-source behaviour is exactly as before.
    //
    // #1450: the kind gets a say, and exactly one: a source with no editable page offers neither. Carnegie
    // is watched at a display-only placeholder over a POST search API, so "Change the page link" would edit a
    // field nothing reads, and "This page is right" would confirm a page that does not exist. It is
    // deliberately keyed on that ONE kind and not on "ingests natively": the other three feed adapters are
    // host-routed at a real URL, which can be the wrong one, so they keep Fix.
    //
    // The rule lives here rather than at each call site because both surfaces used to state it themselves,
    // and stating it as `kind != .algolia` around the whole block is what hid the exit: it took away Fix
    // and Confirm, which was the intent, AND Stop watching, which was not (#1450). Nothing about the kind
    // decides whether a source can be stopped.
    static func offersFix(_ failure: SourceFailure?, kind: SourceKind) -> Bool {
        guard kind.hasEditablePage else { return false }
        return failure?.offersFix ?? true
    }

    // #1521: `hasBytesToConfirm` has NO default, deliberately, and this is #2654's argument in this same
    // file applied to a second parameter. A default here could only be `true` (there are bytes), which is
    // the permissive answer on a control Dan can press, and a permissive default is indistinguishable
    // from a deliberate choice (L113) while failing open on an affordance (L42). Required, every caller
    // states which row it is asking about.
    static func offersConfirm(_ failure: SourceFailure?, kind: SourceKind,
                              readFineAndCameBackEmpty: Bool = false,
                              hasBytesToConfirm: Bool) -> Bool {
        guard kind.hasEditablePage else { return false }
        // #1521: FIRST, before the #2207 short circuit below, and that order is the fix rather than an
        // implementation detail. A confirm with no bytes to anchor to records a judgement about a page
        // nobody has fetched, and `confirmEmpty` answers it with `.noHash`: it clears the failing display,
        // writes no anchor, and the card vanishes. A corrected address is what puts a row in that state.
        //
        // Putting it first is what covers the SILENTLY EMPTY path as well as the failure path #1521 was
        // reported on. Both cards deliberately survive a correction (#1125, #1499, #2207), so both offered
        // Confirm on bytes that no longer exist; had this sat after the short circuit, the readFine path
        // would have kept the defect while looking fixed.
        guard hasBytesToConfirm else { return false }
        // #2207: a page that read fine and returned nothing is the same thing Confirm exists for, whether
        // or not a failure was recorded against it. `confirmEmpty` anchors to the bytes last read either
        // way, so the confirmation means the same and can only ever fail to suppress, never suppress the
        // wrong page.
        if readFineAndCameBackEmpty { return true }
        return failure?.offersConfirm ?? false
    }

    // Whether this component has anything at all to draw. The Sources sheet no longer gates it on the
    // kind, so it is asked to render for Carnegie's row, where it must produce nothing rather than an
    // empty strip of controls.
    static func offersAnything(failure: SourceFailure?, kind: SourceKind, stopWatching: Bool,
                               readFineAndCameBackEmpty: Bool = false,
                               hasBytesToConfirm: Bool) -> Bool {
        stopWatching || offersFix(failure, kind: kind)
            || offersConfirm(failure, kind: kind, readFineAndCameBackEmpty: readFineAndCameBackEmpty,
                             hasBytesToConfirm: hasBytesToConfirm)
    }

    private var offersFix: Bool { Self.offersFix(failure, kind: source.kind) }
    private var offersConfirm: Bool {
        Self.offersConfirm(failure, kind: source.kind, readFineAndCameBackEmpty: readFineAndCameBackEmpty,
                           hasBytesToConfirm: source.hasBytesToConfirm)
    }
    private var offersAnything: Bool {
        Self.offersAnything(failure: failure, kind: source.kind, stopWatching: offersStopWatching,
                            readFineAndCameBackEmpty: readFineAndCameBackEmpty,
                            hasBytesToConfirm: source.hasBytesToConfirm)
    }

    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback

    @State private var editing = false
    @State private var draftURL = ""
    @State private var message: String?

    var body: some View {
        if offersAnything { controls }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xxs) {
            if editing {
                TextField("Their events or season page", text: $draftURL)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onSubmit(saveURL)
            }
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // #1048: warn before a confirm that cannot stick. Gold, not rust: this is guidance, not a
            // failure. Only when confirm is even on offer and the source's read is stale; the popup path
            // is always fresh, so this never appears there. Whether the read is stale is decided in
            // WatchedSource.confirmReadIsStale, never here (#863).
            if offersConfirm, !editing, source.confirmReadIsStale {
                Text(SourceFixConfirmCopy.confirmStaleHint)
                    .font(.system(size: 11)).foregroundStyle(OVColor.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: OVSpacing.xs) {
                Spacer()
                // #1426: leftmost and in the app's quiet secondary tint, because it is the one action here
                // that takes a source off the watchlist rather than repairing it. Hidden while the address
                // editor is open: mid-correction is not the moment to offer removal beside Save.
                if offersStopWatching, !editing {
                    capsule(SourceFixConfirmCopy.stopWatchingTitle, tint: OVColor.inkSoft, action: stopWatching)
                        .help(SourceFixConfirmCopy.stopWatchingHelp)
                }
                if offersConfirm, !editing {
                    capsule(SourceFixConfirmCopy.confirmTitle, tint: OVColor.forestText, action: confirm)
                        .help(SourceFixConfirmCopy.confirmHelp)
                }
                if offersFix {
                    if editing {
                        capsule(SourceFixConfirmCopy.cancelTitle, tint: OVColor.inkSoft) {
                            editing = false; message = nil
                        }
                        capsule(SourceFixConfirmCopy.saveTitle, tint: OVColor.forestText, action: saveURL)
                    } else {
                        capsule(SourceFixConfirmCopy.fixTitle, tint: OVColor.inkSoft) {
                            draftURL = source.listingsURL ?? ""
                            message = nil
                            editing = true
                        }
                        .help(SourceFixConfirmCopy.fixHelp)
                    }
                }
            }
        }
    }

    private func capsule(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        OVCapsuleButton(label: label, tint: tint, action: action)
    }

    // #1417: the edit itself, its wording, and the "only claim success once it saved" rule all live in
    // WatchlistMutations now. What stays here is this editor's own state: which is why .notSaved leaves
    // the field OPEN holding what Dan typed, instead of closing over a correction that never landed.
    private func saveURL() {
        switch WatchlistMutations.fixURL(source, to: draftURL, context: context, feedback: feedback) {
        case .saved(let id):
            editing = false
            message = nil
            onFixed(id)
        case .message(let text):
            message = text
        case .notSaved:
            break
        }
    }

    private func confirm() {
        WatchlistMutations.confirmEmpty(source, context: context, feedback: feedback)
    }

    // #1426: the SAME soft-remove the Sources sheet takes, which is what keeps it reversible: the row, its
    // feed history and the source id stamped on every prospect it ever surfaced all survive, the banner
    // offers an immediate Undo, and the sheet keeps a Watch again that never expires.
    private func stopWatching() {
        WatchlistMutations.stopWatching(source, context: context, feedback: feedback)
    }
}

// The component's own words, kept out of the view body so the copy inventory reads them and a test can
// pin them (#863/#885).
enum SourceFixConfirmCopy {
    // #2263: named after the thing it edits, the PAGE Overture reads, because the row already uses the
    // word address four lines above for the street address that places this source's shows. Two buttons
    // with near-identical names doing unrelated jobs, and the likely misread was the expensive direction:
    // pressing this expecting to correct the street address and being handed the page link instead.
    //
    // It also no longer asserts a diagnosis it has not made. #1177 offers this on every editable row,
    // including a perfectly healthy one, because a wrong page link is plausible anywhere; "Fix" claimed
    // something was wrong with a row where nothing had failed.
    static let fixTitle = "Change the page link"
    static let fixHelp = "Point this source at a different page, then read it to check"
    static let saveTitle = "Save"
    static let cancelTitle = "Cancel"
    static let confirmTitle = "This page is right"
    static let confirmHelp = "Keep this page but stop flagging it, until its contents change"
    // #1426: named once, here, and used by BOTH the Sources sheet's own row control and the scout results
    // popup, so one action cannot end up with two names on two screens.
    static let stopWatchingTitle = "Stop watching"
    static let stopWatchingHelp = "Take this source off the watchlist. You can put it back any time"

    // #1048: shown only in the Sources sheet, only when the page has changed since it was last read (a
    // watch-only pass saw new bytes but did not re-read). Confirming then anchors to the old bytes, so the
    // next read would not match and the source would quietly go on nagging. The popup never shows this: a
    // just-scouted source's read is always current.
    static let confirmStaleHint =
        "The page has changed since it was last read. Confirming now won't stick until you read it again."

    static func fixedAck(org: String) -> String { "Updated \(org)'s address." }
    static func confirmedAck(org: String) -> String {
        "Marked \(org)'s page as right. It won't be flagged again until it changes."
    }
    static func confirmedNoHashAck(org: String) -> String {
        "Cleared the flag on \(org), but read it once so a quiet page can stay quiet."
    }
    static func conflictMessage(org: String) -> String {
        "You already watch \(org) at that address."
    }
}
