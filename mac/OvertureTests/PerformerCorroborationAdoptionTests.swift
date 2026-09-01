import Testing
import Foundation

// #2895: is `performanceCorroborated` actually being emitted, and by how many runs?
//
// This exists because of the shape of the decision. Dan chose, 2026-08-21, that a run saying NOTHING
// changes nothing, which is the same answer #2912 gave for `nameMatchOnly`: his queue does not move and
// the check works on the runs that declare it. What that costs is that the rule is DORMANT until runs
// start declaring, and a dormant rule and a working one look identical from inside the app: every
// contact reads as fine either way (L128, L27).
//
// #2925 is why that is not a hypothetical worry. It asked the same question of `no_route_found`, the last
// field of this kind, and measured ZERO adoptions across 229 real contacts. Without a measurement nobody
// would have known, because the honest default and the ignored instruction are the same absence.
//
// It REPORTS rather than asserting a threshold: nobody has chosen a number that means "adopted", and a
// bar nobody chose is a gate that gets switched off (L93). What it asserts is that it measured something.
@Suite("How often real runs declare performanceCorroborated (#2895)")
struct PerformerCorroborationAdoptionTests {
    // When #2895 shipped. A run before this could not have emitted a field that did not exist, so counting
    // it as a failure to adopt would read the old behaviour as the new defect. Both ends pinned, never one
    // against the live clock (L130).
    private static let valueShippedAt = ISO8601DateFormatter().date(from: "2026-08-21T18:00:00Z")!

    private struct Census {
        var files = 0
        var contacts = 0
        var performerHigh = 0
        var declared = 0
        var declaredFalse = 0
        var filesSince = 0
        var performerHighSince = 0
        var declaredSince = 0
    }

    // The app's OWN rule decides what would be affected, never a predicate written beside it: a second
    // definition drifts, and it drifts towards flattering whichever argument it was written for (L107).
    private func wouldBeHeldDown(_ c: PrepContact) -> Bool {
        ContactConfidenceGuard.holdDown(raw: c.confidence, sourceURL: c.sourceUrl,
                                        nameMatchOnly: c.nameMatchOnly == true,
                                        provenance: c.provenance,
                                        performanceCorroborated: c.performanceCorroborated)
            == .pageDoesNotCorroborate
    }

    private func census() -> Census {
        var c = Census()
        for url in RealResultsFiles.urls() {
            guard let data = try? Data(contentsOf: url),
                  let results = try? PrepResultsDecoder.decode(data) else { continue }
            c.files += 1
            let since = RealResultsFiles.writtenAt(url) >= Self.valueShippedAt
            if since { c.filesSince += 1 }
            for result in results.results {
                for contact in result.contacts ?? [] {
                    c.contacts += 1
                    // The population the rule can speak about at all: a high confidence claim resting on
                    // a named page. A contact not claiming high, or claiming it with no page, is outside
                    // the runbook's rule and outside this count, or the denominator would be every
                    // contact and the ratio would mean nothing.
                    //
                    // #3376 removed the `provenance == "performer"` half of this guard, in step with the
                    // rule itself: the refusal now covers every provenance, and a census still scoped to
                    // performers would go on reporting adoption of a narrower rule than the one that
                    // ships, which is a measurement quietly answering a different question (L220, L63).
                    guard contact.confidence == "high",
                          !(contact.sourceUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    c.performerHigh += 1
                    if since { c.performerHighSince += 1 }
                    if contact.performanceCorroborated != nil {
                        c.declared += 1
                        if since { c.declaredSince += 1 }
                    }
                    if wouldBeHeldDown(contact) { c.declaredFalse += 1 }
                }
            }
        }
        return c
    }

    @Test func countTheDeclarationAcrossEveryRealRunOnThisMac() {
        let c = census()

        // Measured NOTHING is its own outcome, never a reassuring zero: every count below reads as "runs
        // are behaving" on a machine that simply has no runs to read (L98).
        guard c.files > 0, c.contacts > 0 else {
            Issue.record(Comment(rawValue: "no real results file on this machine carried a contact, so "
                                 + "these counts measure nothing. Files read: \(c.files)."))
            return
        }

        print("""
              #2895 census over \(c.files) real results files, \(c.contacts) contacts:
                performer contacts claiming high:  \(c.performerHigh)
                of those, declaring corroboration: \(c.declared)
                declared NOT corroborated:         \(c.declaredFalse)
              files written since the field shipped:      \(c.filesSince)
                performer contacts claiming high in them: \(c.performerHighSince)
                of those, declaring:                      \(c.declaredSince)
              """)

        // The one thing worth asserting. A run written since the field shipped, carrying a performer
        // contact that claims high and declaring nothing, is the dormancy this measurement exists to make
        // visible, and it is reported LOUDLY rather than printed among the numbers, because a line of
        // output nobody reads is the same as no measurement at all.
        if c.performerHighSince > 0 && c.declaredSince == 0 {
            Issue.record(Comment(rawValue: """
                \(c.performerHighSince) performer contacts claiming high have been written since \
                #2895 shipped and NONE of them declared whether the cited page corroborates the \
                performance. The rule is dormant: runs are not emitting the field, so nothing is being \
                held down and the queue looks exactly as it did before. Check that the runbook rule \
                reached the prompt the check actually runs, the way #2925 had to for no_route_found.
                """))
        }
    }

    // The instrument, driven on runs this Mac does not have. A measurement only ever exercised on the data
    // you happen to hold is not exercised, and today this machine holds nothing since the field shipped,
    // so the branch that matters would never run (L140, L101).
    @Test func thecountRecognisesAdeclarationWhenItSeesOne() {
        let declared = PrepContact(name: "Robin Vale", role: "Playwright", email: "robin@vale.example",
                                   method: "named_decision_maker", confidence: "high", formUrl: nil,
                                   provenance: "performer", sourceUrl: "https://vale.example/about",
                                   performanceCorroborated: false)
        let silent = PrepContact(name: "Robin Vale", role: "Playwright", email: "robin@vale.example",
                                 method: "named_decision_maker", confidence: "high", formUrl: nil,
                                 provenance: "performer", sourceUrl: "https://vale.example/about")

        #expect(wouldBeHeldDown(declared))
        #expect(declared.performanceCorroborated != nil)
        #expect(wouldBeHeldDown(silent) == false, "silence changes nothing, which is the whole risk here")
        #expect(silent.performanceCorroborated == nil)
    }
}
