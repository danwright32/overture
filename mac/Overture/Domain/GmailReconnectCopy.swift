import Foundation

// #2967: the words of the "your Gmail access has died" prompt, in one place, because a second screen
// now needs it.
//
// The title, the two buttons and the cause are the SAME on every surface and are shared here, for the
// reason #631 shared the alert itself: two copies of one sentence drift. What is NOT shared is what was
// lost, because that genuinely differs and stating it wrongly is worse than not stating it: a send that
// did not happen is a message a stranger never received, while a conversation that could not be linked
// left the store exactly as it was and nothing went anywhere. A single sentence covering both would
// have to say neither.
enum GmailReconnectCopy {
    static let title = "Reconnect Gmail"
    static let connect = "Connect Gmail"
    static let cancel = "Cancel"

    // Both written out WHOLE, with the shared opening repeated rather than interpolated. Composing
    // them from a `cause` fragment is tidier code and worse copy: `docs/copy-inventory.md` records the
    // literal, so an interpolated sentence reaches it in pieces and the sentence Dan actually reads
    // appears nowhere, which defeats the cold read that file exists for.

    // ONE literal each, not two joined with `+`, however long the line. The inventory records literals,
    // so a sentence built from two of them lands there as two half sentences and the thing Dan reads
    // appears nowhere.

    // A send that did not reach anybody.
    static let afterSend = "Your Gmail access has expired or was revoked, so nothing was sent. Click Connect Gmail to reconnect, then try Send again."

    // #2967: a conversation Overture could not read, so it could not be linked. Nothing was sent and
    // nothing was changed, which is the part Dan needs to know before he goes looking for a side effect.
    static let afterLinkAttempt = "Your Gmail access has expired or was revoked, so this conversation could not be linked. Nothing was sent and nothing changed. Click Connect Gmail to reconnect, then answer again."
}
