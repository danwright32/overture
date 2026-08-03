import Foundation

// #2031: the ONE opening a joint email carries, for the same reason `Recipient.outgoingOpening` exists
// for a single contact (#2010): whatever the app is going to put above the body, Dan has to be able to
// read it and change it, and nothing may be composed at send that he never saw.
//
// It cannot be the per-contact override. One message has one greeting, and a per-contact field would ask
// which of two people's edits wins.
enum JointOpening {
    // A blank override falls back rather than sending a headless email, matching `outgoingOpening`:
    // clearing a field is how somebody undoes an edit, not how they ask for no greeting at all.
    //
    // No per-person `Attn:` line here, deliberately. It names one desk, and on a message several people
    // are reading it would be a true statement about one of them and a puzzle to the rest.
    static func text(for recipients: [Recipient], of prospect: Prospect) -> String {
        if let written = prospect.jointOpeningOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !written.isEmpty {
            return written
        }
        return Salutation.greeting(forGroup: recipients.map(\.name))
    }
}
