import Testing
import Foundation
import SwiftData

// #3959, plan 2.7 and 2.9: what an email promised, frozen when it went, never rewritten by a scout.
//
// Every date and stamp is pinned (L130).
@MainActor
@Suite("A sent email's promised nights are frozen at send (#3959)")
struct PromisedNightsTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theStoredFormRoundTripsAndIsDiscriminated() {
        let promise = PromisedNights(source: .extracted, nights: ["2026-11-13", "2026-11-06", "2026-11-13"],
                                     extractorVersion: 1)
        #expect(promise.nights == ["2026-11-06", "2026-11-13"])
        #expect(PromisedNights(stored: promise.stored) == promise)
        // Stamped and the email named nothing is a real, readable answer, not the absence of one.
        let none = PromisedNights(source: .extracted, nights: [], extractorVersion: 1)
        #expect(PromisedNights(stored: none.stored) == none)
        let notRecorded = PromisedNights(source: .notRecorded, nights: [], extractorVersion: 1)
        #expect(PromisedNights(stored: notRecorded.stored) == notRecorded)
    }

    @Test func aFieldAddedByAFutureBuildIsIgnored() {
        #expect(PromisedNights(stored: "extracted|3|2026-11-06|future=1")?.nights == ["2026-11-06"])
        #expect(PromisedNights(stored: "extracted|3|2026-11-06|future=1")?.extractorVersion == 3)
    }

    @Test func aValueThisBuildCannotReadIsUnreadableNeverEmpty() throws {
        let ctx = ModelContext(try ModelContainer(for: AppSchema.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let r = Recipient(id: "r1", email: "a@example.test", provenance: .act)
        ctx.insert(r)
        #expect(r.promisedNights == .notStamped)
        r.promisedNightsRaw = "guessed|1|"
        #expect(r.promisedNights == .unreadable)
        r.promisedNightsRaw = "extracted|1|not-a-date"
        #expect(r.promisedNights == .unreadable)
    }

    // The extraction is `namedDays`, the one that EXTRACTS, never `finding`, which returns nil on success.
    // A span in the email promises every night inside it, which is what a stranger reading it would take.
    @Test func thePromiseIsTheDatesTheWordsName() {
        let p = PromisedNights.extract(subject: "Photographing your November 6 opening",
                                       body: "I'd love to shoot November 13 to 14 as well.",
                                       performanceDate: "2026-11-06")
        #expect(p.source == .extracted)
        #expect(p.nights == ["2026-11-06", "2026-11-13", "2026-11-14"])
        #expect(p.extractorVersion == EventDateInDraft.namedDaysVersion)
    }

    @Test func noShowDateToAnchorAYearIsNotRecordedRatherThanEmpty() {
        let p = PromisedNights.extract(subject: nil, body: "See you November 6.", performanceDate: nil)
        #expect(p.source == .notRecorded)
    }

    // Write-once: a second stamp can never move what the first email promised.
    @Test func freezingTwiceKeepsTheFirstPromise() throws {
        let ctx = ModelContext(try ModelContainer(for: AppSchema.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let r = Recipient(id: "r1", email: "a@example.test", provenance: .act)
        ctx.insert(r)
        r.freezePromise(subject: nil, body: "November 6", performanceDate: "2026-11-06")
        r.freezePromise(subject: nil, body: "November 20", performanceDate: "2026-11-06")
        #expect(r.promisedNights == .stamped(PromisedNights(source: .extracted, nights: ["2026-11-06"],
                                                            extractorVersion: EventDateInDraft.namedDaysVersion)))
    }

    // Every path that records an outreach as SENT has to stamp it, or a class of sent rows silently has no
    // promise. ENUMERATED from the app's own source by the state reached (a contact's send state set to
    // sent), never from a hand list of writers (L247, L96). Each exemption carries its reason.
    static let exempt: [String: String] = [
        "RecipientBackfill.swift": "repairs contacts sent long before this shipped; answer 6, no backfill",
        "DebugStaging.swift": "Debug only staging rows, never a real send",
        "FollowUpsView.swift": "a SwiftUI preview fixture, never a real send",
    ]

    @Test func everyWriterThatMarksAContactSentAlsoFreezesItsPromise() {
        var writers: [String] = []
        for file in AppSourceWalk.appFiles() where file.text.contains("sendState = .sent") {
            writers.append(file.name)
            guard Self.exempt[file.name] == nil else { continue }
            let sent = file.text.components(separatedBy: "sendState = .sent").count - 1
            let freezes = file.text.components(separatedBy: "freezePromise(").count - 1
            #expect(freezes >= sent,
                    "\(file.name) marks a contact sent \(sent) times and freezes a promise \(freezes) times")
        }
        // The positive control: the two real send paths were found, so the walk is not answering vacuously.
        #expect(writers.contains("SendService.swift") && writers.contains("FormOutreach.swift"),
                "the walk found \(writers), which is not the app's send paths")
        for name in Self.exempt.keys {
            #expect(writers.contains(name), "\(name) no longer marks anything sent; drop its exemption")
        }
    }
}
