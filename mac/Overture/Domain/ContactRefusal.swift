import Foundation
import SwiftData

// #2392: an address Dan has said he does not want to contact.
//
// The one declared home for that fact, because it is read in four places that must agree: the card that
// prints the addresses, the count above them, the importer that would otherwise re-create the contact,
// and the work-list the prep run reads. A rule spread across four readers is how a fact written at one
// level comes to be read at another and goes missing in exactly one direction (L83).
//
// Why a record at all, rather than just deleting the contact: `Prospect.removeOrSuppressRecipient` HARD
// DELETES a still pending recipient, and `PrepImporter` matches an incoming contact to a pending
// recipient or creates one. A deleted row is therefore indistinguishable from one never found, so the
// very next run puts the address straight back. Striking it BEFORE the run is the whole point of #2392,
// so the removal has to be recorded as a refusal the importer reads, never as an absence.
//
// A fully independent entity on the Inquiry / OrgReachabilityAnswer precedent (#1433, #1598): no
// `@Relationship` to Prospect or Recipient, so the migration is purely additive and a prospect being
// dismissed, re-keyed or swept away can never quietly cancel a refusal Dan made.
@Model
final class RefusedContactAddress {
    // scope, its id, and the canonical address, joined. Unique at the STORE layer rather than merely in
    // the code that writes it, so a strike repeated (or written by a second surface) is one refusal and
    // one `allow` clears it.
    @Attribute(.unique) var id: String

    var scopeRaw: String        // "show" | "organisation"
    var scopeId: String         // the prospect's naturalKey, or the OrgKey.stored key
    var emailKey: String        // the canonical address, through ReplyDetection.email
    var refusedAt: Date

    init(id: String, scopeRaw: String, scopeId: String, emailKey: String, refusedAt: Date) {
        self.id = id
        self.scopeRaw = scopeRaw
        self.scopeId = scopeId
        self.emailKey = emailKey
        self.refusedAt = refusedAt
    }
}

@MainActor
enum ContactRefusal {

    // The two levels a refusal can sit at, and the ONLY two. Which one a strike writes is decided by
    // where the address came from, not by the surface it was struck on: a contact this show researched
    // is a fact about this show, while an address printed from the organisation ledger is owned
    // elsewhere and is Dan's call to strike for the organisation (2026-08-09).
    enum Scope: Equatable, Sendable {
        case show(String)
        case organisation(String)

        // The stored spellings, as named constants rather than literals repeated at each comparison: the
        // writer and every reader below share them, so a scope cannot be written one way and looked up
        // another.
        static let showRaw = "show"
        static let organisationRaw = "organisation"

        var raw: String {
            switch self {
            case .show: return Self.showRaw
            case .organisation: return Self.organisationRaw
            }
        }

        var id: String {
            switch self {
            case .show(let key), .organisation(let key): return key
            }
        }
    }

    // The address as everything here compares it. Through the SAME canonicalization a Recipient's id is
    // built from (`Recipient.makeId`), so a refusal and the contact it refuses cannot disagree about
    // which address they name, whatever case or display-name wrapping a run reports it in.
    // `nonisolated` so the Ledger value below (a Sendable struct read off the main actor's store but
    // usable anywhere) can canonicalize through the very same function rather than a second copy of it.
    nonisolated static func key(for email: String?) -> String? {
        guard let email else { return nil }
        let canonical = ReplyDetection.email(from: email)
        return canonical.isEmpty ? nil : canonical
    }

    // The one spelling of a refusal's identity. Both the writer and the reader below go through it, so
    // a strike and the check for it cannot drift into building the same key two different ways.
    nonisolated static func rowId(scopeRaw: String, scopeId: String, emailKey: String) -> String {
        "\(scopeRaw)|\(scopeId)|\(emailKey)"
    }

    private static func rowId(scope: Scope, emailKey: String) -> String {
        rowId(scopeRaw: scope.raw, scopeId: scope.id, emailKey: emailKey)
    }

    // Dan struck this address. Idempotent: the unique id means a repeat is the same refusal rather than
    // a second row that one `allow` would leave standing.
    static func refuse(email: String, scope: Scope, in context: ModelContext, now: Date = Date()) {
        guard let emailKey = key(for: email) else { return }
        let id = rowId(scope: scope, emailKey: emailKey)
        let existing = ((try? context.fetch(FetchDescriptor<RefusedContactAddress>())) ?? [])
        guard !existing.contains(where: { $0.id == id }) else { return }
        context.insert(RefusedContactAddress(id: id, scopeRaw: scope.raw, scopeId: scope.id,
                                             emailKey: emailKey, refusedAt: now))
        try? context.save()
    }

    // The reversal, and the reason triage can follow Dan's no-undo rule for removal at review (#2155,
    // "if they want to add it back they can"). Adding an address back is an explicit statement that it is
    // fine, so it clears the refusal at BOTH levels rather than leaving an organisation-level strike
    // standing behind a contact now sitting on the card.
    static func allow(email: String, showKey: String?, orgKey: String?, in context: ModelContext) {
        guard let emailKey = key(for: email) else { return }
        var ids = Set<String>()
        if let showKey { ids.insert(rowId(scope: .show(showKey), emailKey: emailKey)) }
        if let orgKey { ids.insert(rowId(scope: .organisation(orgKey), emailKey: emailKey)) }
        guard !ids.isEmpty else { return }

        let rows = ((try? context.fetch(FetchDescriptor<RefusedContactAddress>())) ?? [])
            .filter { ids.contains($0.id) }
        guard !rows.isEmpty else { return }
        for row in rows { context.delete(row) }
        try? context.save()
    }

    // Read ONCE per pass and handed to the readers, on the OrgAnswerLedger precedent: a per-row version
    // would re-fetch the whole table for every card drawn.
    static func ledger(in context: ModelContext) -> Ledger {
        ledger(from: (try? context.fetch(FetchDescriptor<RefusedContactAddress>())) ?? [])
    }

    // The same value, from rows a view already holds through its own @Query. Written once here rather
    // than at each of the three surfaces that need it, so the store-to-value mapping cannot drift.
    static func ledger(from rows: [RefusedContactAddress]) -> Ledger {
        Ledger(rows: rows.map { Ledger.Row(scopeRaw: $0.scopeRaw, scopeId: $0.scopeId,
                                           emailKey: $0.emailKey) })
    }

    // The reader, as a value, so every rule that consults it is testable without a store and there is
    // exactly one implementation of "is this address struck".
    struct Ledger: Equatable, Sendable {
        struct Row: Equatable, Hashable, Sendable {
            let scopeRaw: String
            let scopeId: String
            let emailKey: String
        }

        private let rows: [Row]
        private let ids: Set<String>

        static let none = Ledger(rows: [])

        init(rows: [Row]) {
            self.rows = rows
            ids = Set(rows.map {
                ContactRefusal.rowId(scopeRaw: $0.scopeRaw, scopeId: $0.scopeId, emailKey: $0.emailKey)
            })
        }

        var isEmpty: Bool { ids.isEmpty }

        // Struck for THIS show, or for the organisation it belongs to. Either is enough; neither implies
        // the other, which is the whole reason the scope is stored rather than inferred.
        func isRefused(email: String?, showKey: String?, orgKey: String?) -> Bool {
            guard !ids.isEmpty, let emailKey = ContactRefusal.key(for: email) else { return false }
            if let showKey, ids.contains(ContactRefusal.rowId(scopeRaw: Scope.showRaw,
                                                             scopeId: showKey, emailKey: emailKey)) {
                return true
            }
            if let orgKey, ids.contains(ContactRefusal.rowId(scopeRaw: Scope.organisationRaw,
                                                            scopeId: orgKey, emailKey: emailKey)) {
                return true
            }
            return false
        }

        // Every address struck for this show or its organisation, sorted, for the work-list the prep run
        // reads. Sorted so the same store always writes byte-identical JSON: a set's iteration order is
        // not stable, and an unstable queue file makes two identical runs look different in the diff.
        func struckAddresses(showKey: String?, orgKey: String?) -> [String] {
            guard !ids.isEmpty else { return [] }
            var out = Set<String>()
            for row in rows {
                if let showKey, row.scopeRaw == Scope.showRaw, row.scopeId == showKey {
                    out.insert(row.emailKey)
                }
                if let orgKey, row.scopeRaw == Scope.organisationRaw, row.scopeId == orgKey {
                    out.insert(row.emailKey)
                }
            }
            return out.sorted()
        }

        func allowed(_ emails: [String], showKey: String?, orgKey: String?) -> [String] {
            guard !ids.isEmpty else { return emails }
            return emails.filter { !isRefused(email: $0, showKey: showKey, orgKey: orgKey) }
        }

        // The organisation ledger's own answers, with struck addresses taken out before anything reads
        // them. Applied HERE rather than at each card, so the badge ("an email was found") and the
        // addresses printed under it can never disagree: an answer left with no addresses stops being
        // usable at all, which is the promise a count makes about the rows beneath it (L16).
        func allowedAnswers(_ answers: [OrgAnswerLedger.Answer]) -> [OrgAnswerLedger.Answer] {
            guard !ids.isEmpty else { return answers }
            return answers.map { answer in
                let kept = allowed(answer.emails, showKey: nil, orgKey: answer.orgKey)
                guard kept.count != answer.emails.count else { return answer }
                return OrgAnswerLedger.Answer(orgKey: answer.orgKey, result: answer.result,
                                              probedAt: answer.probedAt,
                                              presenterName: answer.presenterName, emails: kept)
            }
        }
    }
}
