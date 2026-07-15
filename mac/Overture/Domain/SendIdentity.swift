import Foundation

// The single identity every manual send goes out as (#360). Both the live GmailSender (via
// ProspectMutations.liveSender) and the SendConfirmation preview read this one value, so the
// "From" Dan confirms in the send sheet can never differ from the "From" the email actually
// sends as. The address lives here and nowhere else; a drift guard test enforces that.
struct SendIdentity: Equatable {
    let name: String
    let email: String

    // copy-inventory:ignore-start  an RFC822 sender identity (name + address), not the app's own voice
    static let danWright = SendIdentity(name: "Dan Wright", email: "dan@danwrightphotography.com")

    // "Dan Wright <dan@danwrightphotography.com>" for the confirmation's From line.
    var display: String { "\(name) <\(email)>" }
    // copy-inventory:ignore-end
}
