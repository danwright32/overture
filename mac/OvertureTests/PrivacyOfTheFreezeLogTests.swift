import Testing
import Foundation

// #3435: whose data the freeze log touches, enforced rather than promised.
//
// The record holds a duration, an instant, a surface, a load class and a load figure. NEVER a prospect
// name, a venue, an address, a subject or a draft body. A durable file on Dan's Mac is a route no
// repository scanner inspects: `scripts/check-test-identity-provenance.sh` and the domain guard read the
// REPOSITORY, and neither can see what the app writes at runtime (L222).
//
// #3435's own "Known defects" section names this as the shape L230 was minted from in this repository,
// twice: a scrub replaced the domain half of an address and left the real person as the local part, and
// the guard written afterwards judged the container. The remedy it prescribes is structural, and this is
// the check that the structure is still there.
@Suite("The freeze log cannot carry Dan's data (#3435)")
struct PrivacyOfTheFreezeLogTests {

    private var model: String { SourceGuardHelper.source("Overture/Domain/MainThreadStall.swift") }
    private var watchdog: String { SourceGuardHelper.source("Overture/Integration/MainThreadWatchdog.swift") }

    // THE ONE THAT MATTERS. A closed enum with no associated values makes a case carrying a group name
    // impossible to write rather than forbidden, which is the difference between a design and a rule
    // living only in prose (L27).
    @Test("the surface is a closed enum with no payload")
    func theSurfaceCarriesNoPayload() {
        let body = try! #require(SourceGuardHelper.between("enum StallSurface", and: "\n}", in: model))
        // Every case, and none of them takes anything. A payload is spelled `case x(String)`, so a `(`
        // anywhere on a case line is the finding.
        let cases = body.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ") }
        #expect(cases.count >= 6, "read only \(cases.count) cases, so this checked almost nothing")
        for line in cases {
            #expect(!line.contains("("),
                    Comment(rawValue: "`\(line.trimmingCharacters(in: .whitespaces))` carries an associated "
                            + "value. A surface case that can hold a String will eventually hold a show's "
                            + "name, in a durable file no scanner inspects (#3435, L230, L222)."))
        }
        // And it is a plain `String` raw value rather than anything derived from a model.
        #expect(model.contains("enum StallSurface: String, Codable, CaseIterable, Sendable"))
    }

    // Every case reachable, so the enum cannot quietly grow one nothing draws or names.
    @Test("every surface case has a sentence")
    func everySurfaceCaseHasASentence() {
        for surface in StallSurface.allCases {
            let clause = FreezeNoticeCopy.surfaceSentence(surface)
            #expect(!clause.isEmpty, "\(surface) renders as nothing, so a freeze there says less than one elsewhere")
        }
        // And no two read the same, or two different findings arrive as one sentence (L11).
        let clauses = StallSurface.allCases.map(FreezeNoticeCopy.surfaceSentence)
        #expect(Set(clauses).count == clauses.count, "two surfaces say the same thing")
    }

    // The record type takes no model. Read from the source rather than from the type system, because the
    // type system would only complain once somebody tried.
    @Test("the record holds no model type and no free text")
    func theRecordHoldsNoModel() {
        let body = try! #require(SourceGuardHelper.between("struct StallRecord", and: "\n}", in: model))
        for forbidden in ["Prospect", "Recipient", "QueueItem", "Inquiry", "WatchedSource"] {
            #expect(!body.contains(forbidden),
                    Comment(rawValue: "StallRecord names \(forbidden). A field that can hold a model can "
                            + "hold a person's name, and this record is written to a durable file (#3435)."))
        }
        // `session` is the only String on it and it is a UUID minted by the watchdog, never anything read
        // off the screen. Asserted because a second String field is exactly how free text arrives.
        let stringFields = body.components(separatedBy: "\n")
            .filter { $0.contains(": String") }
        #expect(stringFields.count == 1,
                Comment(rawValue: "StallRecord now has \(stringFields.count) String fields. The one that "
                        + "is allowed is `session`, a UUID; anything else is free text in a durable file."))
    }

    // The watchdog reads the surface from a BOX the main thread stamps, and never asks the main actor for
    // it. Asking at write time would make the field unavailable at exactly the moment the record is being
    // written, so the guard would fall silent on precisely the input it exists to judge (L345).
    @Test("the watchdog only ever reads the surface, never asks for it")
    func theWatchdogOnlyReadsTheSurface() {
        #expect(watchdog.contains("func stamp(_ surface: StallSurface)"),
                "the main thread has no way to commit the surface")
        #expect(watchdog.contains("var current: StallSurface"),
                "the watchdog has no way to read the committed surface")
        #expect(!watchdog.contains("await MainActor.run"),
                Comment(rawValue: "the watchdog hops to the main actor, which is the one thing that "
                        + "cannot happen while the main thread is wedged (#3435, L345)"))
        // The default is the fourth state, so a stall recorded before anything stamped it has NO surface
        // rather than a wrong one (L11).
        #expect(watchdog.contains("private var value: StallSurface = .notRecorded"))
    }

    // The record is written by the WATCHDOG's queue, not the main thread, or it could not be written
    // during the freeze it records.
    @Test("the record is written off the main thread")
    func theRecordIsWrittenOffTheMainThread() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "ping", in: watchdog))
        // The main closure reads a clock and hops straight back off. Anything else in there is work on
        // the thread this exists to measure.
        #expect(body.contains("self.queue.async { self.recordIfStalled("),
                "the judging and the writing no longer happen on the watchdog's own queue")
        let recorded = try #require(SourceGuardHelper.bodyOfFunction(named: "recordIfStalled", in: watchdog))
        #expect(!recorded.contains("DispatchQueue.main"),
                "the write path touches the main queue, so it cannot run during the freeze it records")
    }

    // NOT the cooperative pool. This blocks by design, waiting on the main thread, and Swift's pool is
    // bounded and does not grow (L241).
    @Test("it runs on a Dispatch queue and not the cooperative pool")
    func itRunsOnADispatchQueue() {
        #expect(watchdog.contains("DispatchQueue(label: \"com.danwright.overture.main-thread-watchdog\""))
        #expect(watchdog.contains("DispatchSource.makeTimerSource"))
        #expect(!watchdog.contains("Task.detached"),
                Comment(rawValue: "the watchdog was moved onto the cooperative pool, which is bounded and does not grow, so "
                + "a blocked ping starves every other piece of concurrent work in the process (L241)"))
    }
}
