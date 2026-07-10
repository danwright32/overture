import Foundation

// One shared greeting in Dan's voice ("Hi <first>,") so FollowUp, ConversationReminder, and the
// per-recipient send greeting (Phase 2.5) all read the same instead of carrying separate copies.
enum Salutation {
    // The recipient's first name, or "there" when we have no usable name.
    static func firstName(_ name: String?) -> String {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "there" }
        return n.split(separator: " ").first.map(String.init) ?? "there"
    }

    // "Hello," when there's no name to greet by (Dan's preferred wording over "Hi there,"),
    // otherwise "Hi <first>,".
    static func greeting(for name: String?) -> String {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "Hello," }
        return "Hi \(firstName(name)),"
    }

    // #610: a generic-inbox address (info@...) has no salutation reason to be personal, but a name
    // Prep found behind it still helps route the email to the right desk. Kept separate from the
    // greeting itself, which stays impersonal since the shared inbox, not this person, is who is
    // actually being addressed. Initial cold pitch only; a threaded follow-up already routed once.
    static func attnLine(for recipient: Recipient) -> String {
        guard recipient.contactMethod == .genericInbox,
              let name = recipient.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return ""
        }
        if let role = recipient.role?.trimmingCharacters(in: .whitespaces), !role.isEmpty {
            return "Attn: \(name), \(role)\n\n"
        }
        return "Attn: \(name)\n\n"
    }

    // #610: a generic-inbox recipient's greeting stays impersonal ("Hello,") even when a name is
    // known, since the Attn: line above carries the name instead; "Hi Jane," would wrongly imply
    // Jane herself is the one opening the shared inbox. Every other recipient greets by name as
    // before.
    static func greeting(for recipient: Recipient) -> String {
        recipient.contactMethod == .genericInbox ? "Hello," : greeting(for: recipient.name)
    }
}
