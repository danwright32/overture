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
    let onSave: (_ email: String, _ name: String?, _ subject: String, _ body: String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var email: String
    @State private var subject = ""
    @State private var emailBody = ""

    init(groupName: String, prefill: ManualPrepPrefill.Result,
         onSave: @escaping (_ email: String, _ name: String?, _ subject: String, _ body: String) -> Void) {
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
            // #2023: what naming several people is about to do, before he saves rather than after. Shown
            // only when there IS more than one, so a single address gains no line (ManualPrepCopy decides).
            if let countNote = ManualPrepCopy.recipientCountNote(for: email) {
                Text(countNote)
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
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
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
            Button {
                onSave(email, nil, subject, emailBody)
                dismiss()
            } label: {
                Text("Save draft")
                    .font(OVType.meta).foregroundStyle(OVColor.onForest)
                    .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                    .background(Capsule().fill(OVColor.forest))
            }
            .buttonStyle(.plain)
            .disabled(!ManualPrepEditing.canSave(email: email, body: emailBody))
        }
    }
}
