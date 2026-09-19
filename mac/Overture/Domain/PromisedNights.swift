import Foundation

// #3959, plan 2.7: what an email that has LEFT THE BUILDING promised, frozen the moment it went.
//
// `runNights` has one writer, the scout's re-fold, and it is right for its own question: what is playing
// now. It was being read for a different one, what did we promise, and nothing marked the moment a send
// made some of those nights a commitment. Found live 2026-09-17: pk 433's sent body names a September
// night and an October night, and its stored nights today hold only the October one, so the September
// night is promised to a stranger and invisible to every check (L192, L37).
//
// So the promise is read out of the words that went, at the moment they went, and never rewritten by any
// scout (Dan's answer 4, 2026-09-17: a night the feed drops after a pitch does not rewrite what was
// promised).
//
// DISCRIMINATED, never a bare array (L544, L192). A bare `[String]` could not tell apart three states a
// reader has to: not stamped (sent before this shipped, or never sent), stamped and the email named no
// night at all, and stamped by a build whose shape this one cannot read.
struct PromisedNights: Equatable, Sendable {

    enum Source: String, Equatable, Sendable {
        // Read out of the sent subject and body by `EventDateInDraft.namedDays`.
        case extracted
        // The send happened and the extraction could not run: the show carried no usable date to anchor
        // a year to, so a bare "March 10" in the email resolves to nothing. Recorded rather than left nil,
        // because nil means "sent before this existed", which would be a false account of this row.
        case notRecorded
    }

    var source: Source
    var nights: [String]            // yyyy-MM-dd, deduplicated, in date order
    // Which extractor read it. The reason this is STORED rather than recomputed from the frozen body: the
    // extractor will change, and a later, better one must be able to re-derive and DISAGREE rather than
    // silently rewrite what the record says (L345). The frozen sent body stays, which is what makes the
    // re-derivation possible.
    var extractorVersion: Int

    // "source|version|night,night". At LEAST three fields, unknown trailing ones ignored, for the reason
    // `NightDecision` gives: an exact arity parser forces a new column the first time a record needs one
    // more fact (L501).
    var stored: String {
        [source.rawValue, String(extractorVersion), nights.joined(separator: ",")].joined(separator: "|")
    }

    init(source: Source, nights: [String], extractorVersion: Int) {
        self.source = source
        self.nights = Array(Set(nights)).sorted()
        self.extractorVersion = extractorVersion
    }

    init?(stored raw: String) {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              let source = Source(rawValue: parts[0]),
              let version = Int(parts[1]) else { return nil }
        let nights = parts[2].split(separator: ",").map(String.init)
        guard nights.allSatisfy({ EasternDate.date(from: $0) != nil }) else { return nil }
        self.init(source: source, nights: nights, extractorVersion: version)
    }

    // The promise of one outgoing email. The subject counts: "Photographing your March 10 opening" in a
    // subject line is as much a promise as the same words in the body.
    static func extract(subject: String?, body: String, performanceDate: String?) -> PromisedNights {
        guard let performanceDate, EasternDate.date(from: performanceDate) != nil else {
            return PromisedNights(source: .notRecorded, nights: [],
                                  extractorVersion: EventDateInDraft.namedDaysVersion)
        }
        let text = [subject, body].compactMap { $0 }.joined(separator: "\n")
        return PromisedNights(source: .extracted,
                              nights: EventDateInDraft.namedDays(in: text, assumingYearOf: performanceDate)
                                  .map(\.day),
                              extractorVersion: EventDateInDraft.namedDaysVersion)
    }
}

// What a contact's stored promise says, including the two ways it can say nothing.
enum PromiseRecord: Equatable, Sendable {
    // Nothing stamped. Sent before this shipped, or not sent. Which of those is the case is a question
    // about `sentAt`, never about this field (plan 2.10: emptiness cannot establish its own cause).
    case notStamped
    case stamped(PromisedNights)
    // A value this build cannot read, most likely written by a newer one. Kept distinct so a reader never
    // renders it as "the email named nothing".
    case unreadable
}

extension Recipient {

    var promisedNights: PromiseRecord {
        guard let raw = promisedNightsRaw else { return .notStamped }
        return PromisedNights(stored: raw).map(PromiseRecord.stamped) ?? .unreadable
    }

    // Written ONCE, when a send commits, in the same write as the receipt fields. Every path that records
    // an outreach as sent calls it: `SendService.deliver`, `SendService.sendJointly` and
    // `Prospect.recordFormOutreach`. Write-once, so a second call (a retried save, a stray re-send) can
    // never move what the first email promised.
    //
    // A send left at `.sending` by a crash between claim and outcome stamps nothing, and there is no
    // in-app path that later marks such a send delivered: `Recipient.isSendStuck` surfaces it for Dan to
    // resolve in Gmail. So those rows read as `notStamped`, which is the honest account: nothing here saw
    // the send complete.
    func freezePromise(subject: String?, body: String, performanceDate: String?) {
        guard promisedNightsRaw == nil else { return }
        promisedNightsRaw = PromisedNights.extract(subject: subject, body: body,
                                                   performanceDate: performanceDate).stored
    }
}
