import Foundation

// One shared greeting in Dan's voice ("Hi <first>,") so FollowUp, ConversationReminder, and the
// per-recipient send greeting (Phase 2.5) all read the same instead of carrying separate copies.
enum Salutation {
    // The recipient's first name, or "there" when we have no usable name.
    static func firstName(_ name: String?) -> String {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "there" }
        return n.split(separator: " ").first.map(String.init) ?? "there"
    }

    static func greeting(for name: String?) -> String {
        "Hi \(firstName(name)),"
    }
}
