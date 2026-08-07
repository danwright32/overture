import SwiftUI

// #360: the words Dan reads at the single most consequential moment (a real email leaving) live
// here in one place, not computed inside the view, so a wording rule can't silently drift under a
// green suite (a lesson from earlier view-embedded logic). SendConfirmSheetTests locks these.
enum SendConfirmCopy {
    static let title = "Send this email now?"
    // #1219: the self double-booking warning shown in the send sheet is now dynamic (it names the clashing
    // show), so it lives in SelfBookingCopy.confirmWarning, set on SendConfirmation.selfBookingWarning.
    static let reassurance = "This sends one email right now, to this recipient only. Nothing else goes out."
    // #2033: the same promise for an email several people are on. It names the number rather than saying
    // "these recipients", because the count is the thing he is checking when he reads the To line above it.
    static func reassuranceForSeveral(_ count: Int) -> String {
        let who = count == 2 ? "both of these people" : "all \(count) of these people"
        return "This sends one email right now, to \(who). Nothing else goes out."
    }
    // #2017: the promise has to follow the TICKS and the together-or-separately choice, both of which Dan
    // can now change on this sheet. Three people on one shared email and three people getting one each are
    // different acts, and this is the sentence he reads immediately before the only irreversible thing the
    // app does, so it says which one is about to happen (L21).
    static func reassurance(chosen: Int, together: Bool) -> String {
        guard chosen > 1 else { return reassurance }
        // One literal, not two concatenated: a split sentence lands in docs/copy-inventory.md as two
        // fragments, and the point of that file is that Dan reads the sentence he will actually see.
        guard together else {
            return "This sends \(chosen) separate emails right now, one to each of these people. Nothing else goes out."
        }
        return reassuranceForSeveral(chosen)
    }
    // #2017: the picker's own labels.
    static let chooseLabel = "Who this goes to"
    static let heldTag = "Held, not sending"
    // #948: the follow-up and conversation-note sends share this sheet. Their heading and reassurance
    // differ from the draft's (and a closing note names the second thing it does), and they live here
    // beside the draft's so all three are read together, in one place, rather than in three view bodies.
    // #2144: a reply gets the same From/To/Subject/preview treatment as everything else that leaves.
    static let replyTitle = "Send this reply now?"
    static let followUpTitle = "Send this follow-up now?"
    static let followUpReassurance = "This sends one follow-up right now, to this recipient only. Nothing else goes out."
    static let noteTitle = "Send this note now?"
    static let noteReassurance = "This sends one message right now, to this recipient only."
    static let noteReassuranceClosing = "This sends one message right now, to this recipient only. It also closes the lead out (kept warm for next time)."
    static let fromLabel = "From"
    static let toLabel = "To"
    static let subjectLabel = "Subject"
    static let previewLabel = "The email that will send"
    static let send = "Send"
    static let cancel = "Cancel"
    // #361: the gold seal on a just-sent row as it leaves the queue.
    static let sentSeal = "Sent"
}

// #360: a first-class, on-brand replacement for the old stock system send-confirm alert. Shows the
// exact From / To / Subject and a scrollable preview of the body about to go out, then the "one
// email, nothing else" reassurance, and a deliberate gold Send that reads as the primary commit.
struct SendConfirmSheet: View {
    let confirmation: SendConfirmation
    let onSend: () -> Void
    let onCancel: () -> Void
    // #2017: rebuilds the confirmation for the current ticks and mode, so the To line, the preview and the
    // promise all describe what pressing Send is about to do rather than what it would have done on open.
    // The greeting differs between one shared email and one each, so a static preview would show a message
    // that is not the one leaving. Dan's rule: "what I see on screen should be what's sent."
    // Nil on the follow-up and note paths, which send to one contact and offer no choice.
    var rebuild: (@MainActor (_ selected: [String], _ together: Bool) -> SendConfirmation?)? = nil
    var onSendSelection: (@MainActor (_ selected: [String], _ together: Bool) -> Void)? = nil

    @State private var selected: [String] = []
    @State private var together = true
    @State private var touched = false

    // What the sheet is currently describing. Falls back to the confirmation it opened with, so a rebuild
    // that cannot produce one (nothing ticked) leaves the screen showing the last good state rather than
    // emptying out under him.
    private var current: SendConfirmation {
        guard touched, let rebuild else { return confirmation }
        return rebuild(selected, together) ?? confirmation
    }

    private var offersChoice: Bool { rebuild != nil && confirmation.candidates.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OVSpacing.sm) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(OVColor.goldBright)
                Text(confirmation.title)
                    .font(OVType.dateHeading)
                    .foregroundStyle(OVColor.onForest)
            }
            .padding(.horizontal, OVSpacing.lg)
            .padding(.vertical, OVSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OVColor.forest)

            VStack(alignment: .leading, spacing: OVSpacing.md) {
                VStack(spacing: 0) {
                    field(SendConfirmCopy.fromLabel, current.from.display)
                    Divider().overlay(OVColor.line)
                    field(SendConfirmCopy.toLabel, current.recipient)
                    Divider().overlay(OVColor.line)
                    field(SendConfirmCopy.subjectLabel, current.subject, emphasised: true)
                }

                // #2017: who it goes to, and how, both decided here. Dan: "Let me pick, and send to
                // several." Shown only where there IS a choice (more than one contact on the show).
                if offersChoice { contactPicker }

                VStack(alignment: .leading, spacing: OVSpacing.xs) {
                    Text(SendConfirmCopy.previewLabel)
                        .font(OVType.meta)
                        .foregroundStyle(OVColor.inkFaint)
                        .textCase(.uppercase)
                    // #2053: the SAME view the draft card previews through, so the last screen before a
                    // real email leaves shows the same message the card showed. It renders the styled
                    // text/html part a mail client displays (the signature Dan sees on the card), and
                    // falls back to the plain-text sign-off exactly where the message has no HTML part.
                    // Drawing `confirmation.body` here showed the fallback part instead, which is a
                    // version of his own signature he has not used since #1144, on the one screen that
                    // is captioned "The email that will send".
                    // #2159: the last screen before a real email leaves, in a 180pt box. A message longer
                    // than that read as the whole message, on the one surface captioned "The email that
                    // will send", so what Dan approved and what left could differ below the fold (L64).
                    CappedScrollView(maxHeight: 180) {
                        DraftSignaturePreview(draftBody: current.bodyBeforeSignOff,
                                              signature: current.signature)
                    }
                    .padding(OVSpacing.sm)
                    .background(OVColor.surfaceSunk)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(OVColor.line))
                }

                // #1219: a self double-booking warning, shown at the committing moment so Dan confirms
                // past it deliberately rather than forgetting he already pitched this date.
                if let warning = current.selfBookingWarning {
                    HStack(alignment: .top, spacing: OVSpacing.xs) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(OVColor.rust)
                            .padding(.top, 1)
                        Text(warning)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OVColor.rust)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: OVSpacing.xs) {
                    Circle().fill(OVColor.gold).frame(width: 6, height: 6).padding(.top, 5)
                    Text(current.reassurance)
                        .font(.system(size: 12))
                        .foregroundStyle(OVColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(SendConfirmCopy.cancel) { onCancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button {
                        if let onSendSelection, touched { onSendSelection(selected, together) } else { onSend() }
                    } label: {
                        Label(SendConfirmCopy.send, systemImage: "paperplane")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(OVColor.gold)
                    // #2017: nothing ticked is nobody to send to, and the button must not offer to do an
                    // action it cannot do. It is the same refusal the send itself makes, at the control.
                    .disabled(offersChoice && selected.isEmpty)
                }
            }
            .padding(OVSpacing.lg)
        }
        .frame(width: 460)
        .background(OVColor.canvas)
        .onAppear {
            selected = confirmation.selected
            together = confirmation.togetherAtOpen
        }
    }

    // #2017: the contacts, ticked. A held contact is listed with its reason and cannot be ticked, so the
    // list never quietly omits somebody on the show (#2015) and a guard cannot be clicked past (#2052).
    @ViewBuilder private var contactPicker: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Text(SendConfirmCopy.chooseLabel)
                .font(OVType.meta).foregroundStyle(OVColor.inkFaint).textCase(.uppercase)
            ForEach(confirmation.candidates) { c in
                Toggle(isOn: Binding(
                    get: { selected.contains(c.id) },
                    set: { on in
                        touched = true
                        if on { if !selected.contains(c.id) { selected.append(c.id) } }
                        else { selected.removeAll { $0 == c.id } }
                    }
                )) {
                    HStack(spacing: OVSpacing.xs) {
                        Text(c.name).font(.system(size: 12)).foregroundStyle(OVColor.ink)
                        Text(c.email).font(OVType.tag).foregroundStyle(OVColor.inkSoft)
                        if c.isHeld {
                            Text(SendConfirmCopy.heldTag).font(OVType.tag).foregroundStyle(OVColor.rust)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(c.isHeld)
            }
            // The event's own together-or-separately choice, reachable at the sending moment. Dan,
            // 2026-08-04: "It should send all three now but also give me the option to put them all on the
            // same email." Same stored choice as the draft card's, not a second one.
            Picker(SendModeCopy.label, selection: Binding(get: { together },
                                                          set: { together = $0; touched = true })) {
                Text(SendModeCopy.together).tag(true)
                Text(SendModeCopy.separately).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(SendModeCopy.label)
            .padding(.top, OVSpacing.xxs)
        }
    }

    private func field(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        HStack(alignment: .top, spacing: OVSpacing.sm) {
            Text(label)
                .font(OVType.meta)
                .foregroundStyle(OVColor.inkFaint)
                .textCase(.uppercase)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(emphasised ? OVType.body.weight(.medium) : OVType.body)
                .foregroundStyle(OVColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, OVSpacing.xs)
    }
}

// #2033: the tag on a contact row saying this email is going to them. Out of the view because a view that
// computes its own wording drifts under a green suite (ViewCopyGuardTests).
enum DraftContactCopy {
    static func nextSendTag(recipients: Int) -> String {
        recipients > 1 ? "On this email" : "Sending to this one"
    }
}

// #2034: the words on the switch that decides whether an event's contacts share one email. Out of the
// view, like every other sentence, so the wording is testable and shows up in the copy inventory.
enum SendModeCopy {
    static let label = "How this goes out"
    static let together = "One email to everyone"
    static let separately = "A separate email each"
}
