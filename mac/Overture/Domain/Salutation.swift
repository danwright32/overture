import Foundation

// #2545 shrank this to what a body Overture writes END TO END still needs. The follow-up
// (`FollowUp.swift`) and the post-event prompt (`PostEventPrompt.swift`) compose their greeting inside
// their own body, so they never had the doubling this issue fixed, and they still need a greeting built
// from a name.
//
// What went is everything that composed an opening ABOVE a body Dan reviews: `attnLine(for:)`, the
// per-recipient `greeting(for:)` and `greeting(forGroup:)`. A pitch's greeting is the drafter's job now,
// and nothing here may be reached from the pitch path again, because two places that can greet is
// exactly the defect #2545 removed.
enum Salutation {
    static func firstName(_ name: String?) -> String {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "there" }
        return n.split(separator: " ").first.map(String.init) ?? "there"
    }

    static func greeting(for name: String?) -> String {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "Hello," }
        return "Hi \(firstName(name)),"
    }
}
