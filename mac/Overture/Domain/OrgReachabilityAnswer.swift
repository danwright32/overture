import Foundation
import SwiftData

// #1598 (milestone 32 Phase 5.1): what a reachability check concluded about an ORGANISATION, kept so a
// second show by the same organisation never has to be paid for again.
//
// A fully independent entity on the Inquiry precedent (#1433): zero `@Relationship` to Prospect or
// Recipient, so adding it is a purely additive migration and a prospect being dismissed, re-keyed or
// swept away can never take an answer Dan paid for with it. That independence is the point: the
// alternative, deriving the answer from whichever rows happen to be in the queue, means dismissing one
// show quietly evaporates an answer, and nothing on screen would ever reveal it.
//
// Auditable on purpose. This is a record of what Dan spent tokens on, not a black box: it carries the
// show that was actually paid for and the addresses that earned the verdict, so any later question about
// why a row claims a contact can be answered from the store.
@Model
final class OrgReachabilityAnswer {
    // The namespaced organisation identity (OrgKey.stored). Unique at the STORE layer, not merely in the
    // code that writes it, so two settlements racing on the same organisation cannot leave two answers
    // that disagree.
    @Attribute(.unique) var orgKey: String

    // What the check concluded, raw so a value written by a future version decodes here without a
    // migration. Mirrors Prospect.reachabilityResultRaw exactly; both read Reachability.ProbeResult.
    var resultRaw: String

    // When the check that produced this answer ran. An inherited answer carries THIS date, never the
    // date it was inherited, so an organisation ages out of the freshness window instead of renewing
    // itself forever as it acquires new shows.
    var probedAt: Date

    // The show that was actually researched and paid for, and the presenter string as the page wrote it.
    var sourceNaturalKey: String
    var sourceGroupName: String
    var presenterName: String

    // The addresses that earned an `emailFound` verdict, newline separated. SENDABLE ones only,
    // deliberately: a venue front desk or a press inbox is a fact about the room this one show played,
    // and repeating it on the organisation's show at some other venue would be wrong twice over.
    var foundEmailsRaw: String

    init(orgKey: String, result: Reachability.ProbeResult, probedAt: Date,
         sourceNaturalKey: String, sourceGroupName: String, presenterName: String,
         foundEmails: [String] = []) {
        self.orgKey = orgKey
        self.resultRaw = result.rawValue
        self.probedAt = probedAt
        self.sourceNaturalKey = sourceNaturalKey
        self.sourceGroupName = sourceGroupName
        self.presenterName = presenterName
        self.foundEmailsRaw = foundEmails.joined(separator: "\n")
    }

    // nil when a future version wrote a verdict this build cannot read. An unreadable value must never be
    // reported as one of today's answers (#1596's own rule, kept here).
    var result: Reachability.ProbeResult? {
        Reachability.ProbeResult(rawValue: resultRaw)
    }

    var foundEmails: [String] {
        foundEmailsRaw.split(separator: "\n").map(String.init)
    }

    // Move an organisation's answer forward when a newer check settles. Older evidence never overwrites
    // newer: a re-settle of a run that already landed, or a stale results file consumed twice, must not
    // walk a fresh answer backwards.
    func update(result: Reachability.ProbeResult, probedAt: Date, sourceNaturalKey: String,
                sourceGroupName: String, presenterName: String, foundEmails: [String]) {
        guard probedAt >= self.probedAt else { return }
        self.resultRaw = result.rawValue
        self.probedAt = probedAt
        self.sourceNaturalKey = sourceNaturalKey
        self.sourceGroupName = sourceGroupName
        self.presenterName = presenterName
        self.foundEmailsRaw = foundEmails.joined(separator: "\n")
    }
}

// #1598 Phase 5: the ONE place an organisation's answer is written down. Kept out of the settlement
// function it is called from so the rules are reachable by a test (#863), and deliberately a single
// writer: the row's own result already has three (#1596), and a fourth opinion about the same check
// living somewhere else is how two surfaces come to disagree about what Dan paid for.
@MainActor
enum OrgAnswerRecording {

    // Called AFTER the ingest has run, so the venue and press guards have classified whatever came back
    // and a found contact can be told from a front desk.
    //
    // `answeredKeys` is the set of shows the run genuinely ANSWERED (#1594: the marker intersected with
    // the results file), never the set it was asked about. A show the run never reached has no answer,
    // and inventing "no email found" for its whole organisation would be invisible and would stand for
    // 90 days.
    @discardableResult
    static func record(answeredKeys: Set<String>, in context: ModelContext, now: Date) -> Int {
        guard !answeredKeys.isEmpty else { return 0 }
        let prospects = ((try? context.fetch(FetchDescriptor<Prospect>())) ?? [])
            .filter { answeredKeys.contains($0.naturalKey) }
        guard !prospects.isEmpty else { return 0 }

        let existing = ((try? context.fetch(FetchDescriptor<OrgReachabilityAnswer>())) ?? [])
        var byKey = Dictionary(existing.map { ($0.orgKey, $0) }, uniquingKeysWith: { a, _ in a })
        var written = 0

        for p in prospects {
            guard let presenter = p.presenter, let orgKey = OrgKey.stored(for: presenter) else { continue }
            // Classified from the row's RECIPIENTS through the one shared definition (#1596), not from
            // its stored result: markProbed writes a pre-guard "no email found" floor before the ingest
            // runs, and a re-settle of an already consumed results file leaves that floor standing on a
            // row that plainly carries a contact.
            let result = p.reachabilityResultFromRecipients
            // Sendable addresses only. An address held by the venue or press guard belongs to the room
            // this one show played, not to the organisation, so it must not ride to another venue.
            let emails = result == .emailFound
                ? p.recipients.filter(\.isSendablePending).compactMap(\.email).filter { !$0.isEmpty }
                : []

            if let row = byKey[orgKey] {
                row.update(result: result, probedAt: now, sourceNaturalKey: p.naturalKey,
                           sourceGroupName: p.groupName, presenterName: presenter, foundEmails: emails)
            } else {
                let row = OrgReachabilityAnswer(orgKey: orgKey, result: result, probedAt: now,
                                                sourceNaturalKey: p.naturalKey,
                                                sourceGroupName: p.groupName, presenterName: presenter,
                                                foundEmails: emails)
                context.insert(row)
                byKey[orgKey] = row
            }
            written += 1
        }

        do {
            try context.save()
        } catch {
            // Fail loud. A silently dropped ledger row is money already spent that Overture will spend
            // again, and nothing on screen would ever say so.
            // copy-inventory:ignore-start  a diagnostic log line, not a sentence Overture says on screen
            NSLog("could not record %d organisation reachability answers: %@",
                  written, error.localizedDescription)
            // copy-inventory:ignore-end
            return 0
        }
        return written
    }
}
