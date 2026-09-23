import SwiftUI
import SwiftData

// #4170: the panel behind "Pitch someone else", opened from the Close this out menu on a sent row.
//
// A SHEET rather than a field revealed on the row, for the reason `CloseOutMenu` is its own view: the
// reached-out row's trailing column is governed by a stated ceiling (#2167, `ReachedOutRowSlots`), and
// a field that appears in it is a second control there whenever it is open. It is also the shape the
// act deserves: this spends money on the next Prep run and writes to somebody new, which is not a
// one-key edit.
//
// It takes a ROUTE, not an address, because that is what every other hand-added contact in this app
// takes since #2629: an email, a contact form, or a social profile, judged by the one
// `ManualContactRoute.parse` the Add button is gated on, so the control can never look willing to take
// something the action then refuses (L109).
struct PitchSomeoneElseSheet: View {
    let prospect: Prospect
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback
    @State private var route = ""
    @State private var name = ""
    @FocusState private var routeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            Text(RePitchCopy.panelTitle).font(OVType.groupName)
            // The show, so the panel says which one it is about: it is opened from a row and read on a
            // sheet that covers it (L287, a notice must state its own scope).
            Text(prospect.groupName).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            Text(RePitchCopy.panelHelp).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            TextField(ContactFieldCopy.routePlaceholder, text: $route)
                .textFieldStyle(.roundedBorder)
                .focused($routeFocused)
                .onSubmit(add)
            TextField(ContactFieldCopy.namePlaceholder, text: $name)
                .textFieldStyle(.roundedBorder)
                // Return adds, from EITHER field, rather than falling through to whatever default button
                // the sheet happens to carry, which is the defect #2308 shipped once already. It is the
                // same act the button below performs and is gated on the same parse, so a Return with no
                // usable route does nothing at all.
                .onSubmit(add)

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                Button(RePitchCopy.addAction) { add() }
                    .keyboardShortcut(.defaultAction)
                    // The same rule the write is gated on, so the button cannot look willing to take
                    // something `pitchSomeoneElse` then refuses.
                    .disabled(ManualContactRoute.parse(route) == nil)
            }
        }
        .padding(OVSpacing.lg)
        .frame(width: 420)
        .background(OVColor.surface)
        .onAppear { routeFocused = true }
    }

    private func add() {
        guard ManualContactRoute.parse(route) != nil else { return }
        ProspectMutations.pitchSomeoneElse(prospect, route: route,
                                           name: name.isEmpty ? nil : name,
                                           context: context, feedback: feedback)
        onClose()
    }
}
