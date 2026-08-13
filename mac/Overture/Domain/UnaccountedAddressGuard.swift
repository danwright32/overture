import Foundation

// #2624: a stored contact that names one person and holds a different person's address, with no page
// cited. The greeting is composed from the contact's `name`, so a pitch to it would open by addressing the
// artist and arrive in a third person's inbox at an agency: L75's failure exactly, where identifying who
// an outward action targets has failed, something nearby is substituted silently, and it looks like success.
//
// LIVE-STORE-CLAIM verified=2026-08-13 measure="ZRECIPIENT rows with an address, against this predicate"
// The row: "Jordan Smart / Jay Skaggs", name `Jordan Smart` (the artist), role `Booking (Ground Control
// Touring)`, address `tommy@` the agency's domain, no `contactSourceURL`, confidence `low`. It asserts a
// named decision maker while naming nobody who owns that address.
//
// THE HARD PART IS NOT FIRING ON EVERYTHING ELSE (L104: a filter that identifies data by its SHAPE has to
// be tested against what it must PRESERVE). Measured on a snapshot of the live store on 2026-08-13, over
// all 89 stored addresses, of which 70 carry a name and 64 cite a page:
//
//   - "the local part shares no word with the stored name" alone fires on 24 of the 70. Almost all are
//     ordinary and correct: a producer at their own company's `hello@`, a manager at an agency `info@`.
//   - adding "and no page was cited" narrows it to 9 rows (6 distinct contacts).
//   - adding the shared-inbox and the show-or-organisation tests below leaves exactly ONE: the row above.
//
// So this is a guard with one measured instance rather than a rule that repaints the queue. Like the four
// guards beside it, it is a heuristic and it is DISMISSIBLE: Dan can look at an address and judge it.
enum UnaccountedAddressGuard {
    // A shared inbox is not a person, so it can never be "somebody else's" name. This is the test that
    // keeps the 5 measured rows at `admin@`, `info@` and `office@` out, and it is deliberately generous:
    // a false NEGATIVE here is only the status quo, while a false positive holds a real contact back.
    private static let sharedInboxWords = [
        "info", "admin", "office", "hello", "contact", "booking", "bookings", "press", "media",
        "tickets", "boxoffice", "mail", "email", "team", "general", "inquiries", "enquiries",
        "inquiry", "enquiry", "sales", "support", "events", "artists", "management", "reservations",
        "frontdesk", "hi", "hey", "help", "studio", "orders", "accounts", "billing", "marketing",
        "production", "productions", "publicity", "outreach", "education", "boxoffice", "welcome",
        "connect", "reach", "talk", "ask", "hola", "theatre", "theater", "music", "artistic",
    ]

    // True when NOTHING recorded on the row accounts for who this address belongs to.
    //
    // Every input is a thing the address could legitimately belong to: the contact themselves, the show,
    // or the organisation presenting it. An address matching any of them is accounted for. An address
    // matching none of them, with no page cited to explain it, names somebody nobody recorded.
    static func looksLikeAnotherPersons(email: String?, name: String?, sourceURL: String?,
                                        groupName: String?, presenter: String?) -> Bool {
        // With no name there is no claim to contradict: a bare address is honestly a bare address, which
        // is the common case (19 of the 89 measured rows) and a different issue entirely (#2625).
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let email, let local = localPart(of: email), !local.isEmpty else { return false }
        // A cited page is the evidence the runbook asks for, and #2382 explicitly allows a representative
        // named on the target's OWN page. Four of the six representative contacts in the store are exactly
        // that and must stay untouched.
        guard (sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let core = slug(local)
        guard !core.isEmpty else { return false }
        if sharedInboxWords.contains(where: { core.contains($0) }) { return false }
        // The show's own name and the presenting organisation's, because an address at either is the act's
        // rather than a stranger's. This is what keeps a show inbox (measured: `BwaySessions@` on Ben
        // Cameron's "Broadway Sessions") out of a rule about people.
        let accountedFor = words(name) + words(groupName) + words(presenter)
        return !accountedFor.contains { core.contains($0) }
    }

    private static func localPart(of email: String) -> String? {
        guard let at = email.firstIndex(of: "@") else { return nil }
        // A plus-tag is addressing, not identity: "tommy+shows@" is still Tommy.
        return String(email[..<at]).split(separator: "+").first.map(String.init)
    }

    // Words worth matching on. Three letters and up, so an initial or a stray particle ("de", "of") cannot
    // account for an address by accident.
    private static func words(_ s: String?) -> [String] {
        (s ?? "").split(whereSeparator: { !$0.isLetter })
            .map { slug(String($0)) }
            .filter { $0.count >= 3 }
    }

    private static func slug(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
