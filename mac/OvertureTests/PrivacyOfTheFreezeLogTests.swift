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
        // `session` is the only String STORED on it and it is a UUID minted by the watchdog, never
        // anything read off the screen. Asserted because a second String field is exactly how free text
        // arrives.
        //
        // STORED is the word that matters, and it is narrower than this used to be. A computed property
        // holds nothing: it can only restate what the stored fields already carry, so counting it as a
        // field reported `identity` (a session and a sequence number) as free text in a durable file,
        // which is a finding about the guard rather than about the record. What makes that narrowing
        // safe is asserted below rather than assumed, because a computed property in Swift may call
        // anything at all, including something that reads the store (L324).
        let declarations = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("let ") || $0.hasPrefix("var ") }
        let stored = declarations.filter { !$0.contains("{") }
        let storedStrings = stored.filter { $0.contains(": String") }
        #expect(storedStrings.count == 1,
                Comment(rawValue: "StallRecord now stores \(storedStrings.count) String fields. The one "
                        + "that is allowed is `session`, a UUID; anything else is free text in a durable "
                        + "file."))

        // THE OTHER HALF. Every computed property on the record may name only the record's own stored
        // fields, and may reach through nothing (no `.`), so it cannot pull in a model, a store, a
        // default or a screen. Without this the narrowing above would be an exemption rather than a
        // rule, and the field that escapes is always the one added last (L360).
        let storedNames = Set(stored.compactMap { line -> String? in
            let afterKeyword = line.dropFirst(4)
            guard let colon = afterKeyword.firstIndex(of: ":") else { return nil }
            return String(afterKeyword[..<colon]).trimmingCharacters(in: .whitespaces)
        })
        #expect(storedNames.count == stored.count,
                Comment(rawValue: "could not read a name for every stored field (\(storedNames.count) of "
                        + "\(stored.count)), so the rule below is judging against a short list"))
        let computed = declarations.filter { $0.contains("{") }
        #expect(computed.contains(where: { $0.contains("identity") }),
                Comment(rawValue: "no computed `identity` was found on StallRecord, so this rule measured "
                        + "nothing; the reporter keys what it has already said on that value (L98)"))
        for line in computed {
            guard let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}") else {
                Issue.record("computed property spans more than one line, which this rule cannot read: \(line)")
                continue
            }
            let expression = String(line[line.index(after: open)..<close])
            #expect(!expression.contains("."),
                    Comment(rawValue: "`\(line)` reaches through a dot, so it can call out to anything, "
                            + "including something that reads the store, and whatever it returns is "
                            + "written to a durable file (#3435, L222)"))
            let names = expression.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
            for name in names {
                #expect(storedNames.contains(name),
                        Comment(rawValue: "`\(line)` names `\(name)`, which is not a stored field of "
                                + "StallRecord, so this record can carry something nobody declared"))
            }
        }
    }

    // #3763: the committed BASELINE is a second place this data lives, and it is in a PUBLIC repository.
    //
    // `fixtures/freeze-log-baseline-20260910.ndjson` is 686 real records off Dan's Mac, kept because
    // milestone 80's before and after comparison is read from them and a relaunch discards the oldest
    // (686 against a `FreezeLog.fileCap` of 500, so 186 would have gone). Everything above this test
    // guards the SHAPE of a record as the app writes it; nothing guarded a file of real ones checked in.
    //
    // The permitted keys are DERIVED from `StallRecord`'s own stored properties rather than listed here,
    // so a field added to the record later cannot arrive in this fixture unexamined, and a hand list
    // cannot drift from the type it is supposed to describe (L41, L96).
    @Test("the committed freeze baseline carries only the record's own stored fields")
    func theCommittedBaselineCarriesNothingElse() throws {
        let url = RepoRoot.url.appendingPathComponent("fixtures/freeze-log-baseline-20260910.ndjson")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "the committed freeze baseline is missing, so this guard measured nothing")
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        // A FLOOR, so a truncated or emptied fixture is a failure rather than a clean pass over nothing
        // (L98). The file held 686 when it was committed; anything near that is fine, nothing is not.
        #expect(lines.count > 600, "read only \(lines.count) records, so this guard checked almost nothing")

        let body = try #require(SourceGuardHelper.between("struct StallRecord", and: "\n}", in: model))
        let stored = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ($0.hasPrefix("let ") || $0.hasPrefix("var ")) && !$0.contains("{") }
        let permitted = Set(stored.compactMap { line -> String? in
            let afterKeyword = line.dropFirst(4)
            guard let colon = afterKeyword.firstIndex(of: ":") else { return nil }
            return String(afterKeyword[..<colon]).trimmingCharacters(in: .whitespaces)
        })
        #expect(permitted.count >= 6,
                "read only \(permitted.count) stored fields off StallRecord, so the rule below judges against a short list")

        var seen = Set<String>()
        for line in lines {
            let object = try #require(try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                                      "a line of the committed baseline is not an object")
            seen.formUnion(object.keys)
        }
        let unexpected = seen.subtracting(permitted).sorted()
        #expect(unexpected.isEmpty, Comment(rawValue:
            "the committed baseline carries \(unexpected.joined(separator: ", ")), which is not a stored "
            + "field of StallRecord. A key nobody declared is a key nobody checked for a person's name, "
            + "in a file in a PUBLIC repository (#3763, L222)."))

        // And the surface really is only ever the enum's own spelling, never free text that happened to
        // parse. This is the half a key check cannot see.
        let allowedSurfaces = Set(StallSurface.allCases.map(\.rawValue))
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let surface = object["surface"] as? String else { continue }
            #expect(allowedSurfaces.contains(surface),
                    Comment(rawValue: "the committed baseline carries surface `\(surface)`, which is not a "
                            + "StallSurface case, so something wrote free text into it"))
        }
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
        //
        // Asserted as the RULE rather than as one spelling of it (L103). This used to match the exact
        // text `self.queue.async { self.recordIfStalled(`, and #3635 added a line inside that same block
        // (releasing the in-flight flag), which is the refinement the rule permits and the spelling did
        // not: the guard went red while the property it protects was untouched.
        let hop = "self.queue.async"
        let hopAt = try #require(body.range(of: hop), "the ping never hops back to the watchdog's queue")
        #expect(!body[body.startIndex..<hopAt.lowerBound].contains("recordIfStalled("),
                Comment(rawValue: "the ping judges or writes BEFORE hopping back to the watchdog's own "
                        + "queue, so that work happens on the main thread this exists to measure and "
                        + "cannot run during the freeze it records (#3435)."))
        #expect(body[hopAt.lowerBound...].contains("recordIfStalled("),
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
