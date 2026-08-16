import SwiftUI

// #2007: "Prep manually." Dan writes the email himself, with no Prep run and no model call.
//
// For the shows an AI draft helps least and costs most: an annual booking he has shot five years
// running, where the email is one paragraph asking about this year's dates, and the drafter's
// cold-pitch shape gets rewritten anyway.
//
// Every rule here lives outside the view (#863): what prefills the address (`ManualPrepPrefill`), the
// words about it (`ManualPrepCopy`), and what Save will accept (`ManualPrepEditing`). This draws them.
struct ManualPrepSheet: View {
    let groupName: String
    // A plain VALUE, already looked up by the caller. The lookup itself is expensive (it walks every
    // prospect and reads the booking-history file), so it happens in the row's sheet closure, which runs
    // only when the sheet is actually presented; `ManualPrepOnScreenTests` is what holds that.
    // Taking the answer rather than a closure keeps this view a pure function of what it is given.
    let prefill: ManualPrepPrefill.Result
    let onSave: (_ email: String, _ name: String?, _ subject: String, _ body: String, _ sendsTogether: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var email: String
    @State private var subject = ""
    @State private var emailBody = ""
    // #2034: together is the default he asked for, on this sheet as well as on an AI draft.
    @State private var sendsTogether = true

    init(groupName: String, prefill: ManualPrepPrefill.Result,
         onSave: @escaping (_ email: String, _ name: String?, _ subject: String, _ body: String, _ sendsTogether: Bool) -> Void) {
        self.groupName = groupName
        self.prefill = prefill
        self.onSave = onSave
        // Seeded ONCE, at construction, rather than written on each appearance: a redraw must never
        // overwrite an address Dan has started typing.
        _email = State(initialValue: prefill.filled?.email ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            header
            recipientField
            subjectAndBody
            footer
        }
        .padding(OVSpacing.lg)
        .frame(width: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ManualPrepCopy.editorTitle(groupName: groupName))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
            Text("Nothing is drafted for you and no Prep run is started.")
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recipientField: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            TextField("Send to", text: $email).textFieldStyle(.roundedBorder)
            // #2023: this field takes as many people as he needs, and it looks exactly like the box that
            // took one, so the line says so until there IS a second address and then says what the ones he
            // typed will do. Which of the two it is belongs to ManualPrepCopy, not to this view.
            Text(ManualPrepCopy.addressFieldNote(for: email))
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            // #2034: the choice, offered only once a second address makes it one. The line above says
            // what it is currently set to, so the two read as one statement rather than two.
            if case .addresses(let list) = EmailAddressList.parse(email), list.count > 1 {
                Picker(SendModeCopy.label, selection: $sendsTogether) {
                    Text(SendModeCopy.together).tag(true)
                    Text(SendModeCopy.separately).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(SendModeCopy.label)
            }
            if let filled = prefill.filled {
                Text(ManualPrepCopy.filledRecipientNote(filled, prepping: groupName))
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Offered, never filled in. An address off the booking sheet or out of Overture's own
            // research is one nobody has written to, and a prefilled field does not invite the second
            // look that catches an agent's address sitting in the org's column.
            ForEach(prefill.suggestions, id: \.email) { suggestion in
                HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
                    Button(suggestion.email) { email = suggestion.email }
                        .buttonStyle(.link).font(OVType.meta)
                    Text(ManualPrepCopy.suggestionNote(suggestion.source))
                        .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let reason = prefill.emptyReason {
                Text(ManualPrepCopy.emptyRecipientNote(reason))
                    .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subjectAndBody: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
            TextEditor(text: $emailBody)
                .font(OVType.body)
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OVColor.line))
            // #2574: under the field it is about, unlike the Save refusal, which sits beside the button
            // for the #843 reason given below. This one names the BODY, so anywhere else would make him
            // look for which box it meant. It never disables anything: the send hold is the rule, and it
            // has an override.
            if let hint = ManualPrepEditing.greetingHint(body: emailBody) {
                Text(hint)
                    .font(OVType.tag)
                    .foregroundStyle(OVColor.inkSoft)
            }
        }
    }

    // #2544: the reason Save draft is refusing, taken from the same call that decides whether it is
    // refusing at all. Dan met the grey button with the Subject box empty and nothing on screen joining
    // the two, while the app had already computed the sentence and thrown it away.
    //
    // Shown at rest, from the moment the sheet opens, rather than waiting until he has typed something. The
    // alternative leaves exactly the state he reported reachable: a control that is off with no reason
    // beside it. The wording is what to do next ("Add a subject line"), not a report on a press, so it
    // reads as the label on a control that is not ready yet rather than as a scolding.
    //
    // It sits beside the button and not under the field it names, so it cannot become a second line saying
    // what the address field's own note already says (#843).
    private var footer: some View {
        let reason = ManualPrepEditing.reasonSaveIsDisabled(email: email, subject: subject, body: emailBody)
        return HStack(alignment: .firstTextBaseline) {
            if let reason {
                Text(reason)
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
            Button {
                onSave(email, nil, subject, emailBody, sendsTogether)
                dismiss()
            } label: {
                Text("Save draft")
                    .font(OVType.meta).foregroundStyle(OVColor.onForest)
                    .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                    .background(Capsule().fill(OVColor.forest))
            }
            .buttonStyle(.plain)
            .disabled(reason != nil)
            // A dimmed control with no label is unreadable to VoiceOver as well as to the eye, and the
            // pointer asks the same question the eye does.
            .accessibilityHint(reason ?? "")
            .help(reason ?? "")
        }
    }
}
