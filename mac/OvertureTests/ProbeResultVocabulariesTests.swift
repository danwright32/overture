import Testing
import Foundation

// #2528: one fact about a show, spelled three times.
//
// A reachability check concludes one of four things (`Reachability.ProbeResult`). `ContactRoute`
// (Ranker.swift) names those same four a second time so the fit score can weigh them, and
// `Reachability.Badge` names them a third time so the row can say them. `ContactRoute.init(probeResult:)`
// and `Reachability.badge(result:...)` map one onto the other case by case.
//
// Today both mappings are exhaustive switches with no `default:`, so the compiler happens to break the
// build when a fifth probe result is added. That is accidental protection, not a guard: the moment
// somebody writes a `default:` to clear the compile error, a new probe result lands silently in
// whichever route or badge the default names. The show would then be scored on the wrong contact route
// (`Ranker.contactRoutePoints`) or wear a badge saying something the check never found, and nothing
// would go red. This is LESSONS L113: a lookup keyed by a vocabulary needs its completeness enforced,
// because a missing key takes the default branch and a default is indistinguishable from a deliberate
// choice.
//
// #1841's fix (wrap the source enum so there is only ever one list) deliberately does NOT transfer
// here. `ContactRoute` is String-raw-valued and Decodable, read from a stored raw value and from JSON,
// so its cases are a persisted contract; `Badge` is a UI vocabulary whose four extra cases are
// deliberately not probe results (#1722). So this is the other half of that choice: the two lists stay,
// and a test holds them in step.
//
// Every list below is DERIVED (`allCases` on all three enums, and real calls into the two mappings).
// Nothing here restates a vocabulary, because a hand-written registry only ever checks the entries
// somebody remembered (L96), which is the same defect wearing a test's clothes.
@Suite("ProbeResult, ContactRoute and Badge stay in step (#2528)")
struct ProbeResultVocabulariesTests {

    // A fresh probe with an ordinary show underneath it, so nothing but the probe result can decide the
    // badge: not staleness, not an inherited answer, not a missed check, and not the free heuristic
    // (a named presenter on a normal listing with a real website).
    private static func freshBadge(for result: Reachability.ProbeResult) -> Reachability.Badge {
        Reachability.badge(result: result, probeIsStale: false, inherited: nil, missedByACheck: false,
                           presenter: "A Presenting Organisation",
                           sourceListingURL: "https://example.org/listing")
    }

    private static var allProbeResults: [Reachability.ProbeResult] { Reachability.ProbeResult.allCases }

    // MARK: the route the fit score reads

    // Four verdicts, four routes. A `default:` in `init(probeResult:)` would land a fifth verdict on
    // whichever route it names, and two verdicts sharing one route is exactly the miscount: a show whose
    // check found a contact form would be scored as one that found nothing.
    @Test func everyProbeResultGetsItsOwnContactRoute() {
        let routes = Self.allProbeResults.map { ContactRoute(probeResult: $0) }
        #expect(Set(routes).count == Self.allProbeResults.count,
                "two probe results share one ContactRoute, so the fit score cannot tell them apart")
    }

    // `unchecked` means nobody asked, and it must stay scoreless for that reason (Ranker's own comment).
    // A `default: self = .unchecked` is the cheapest way to clear the compile error a new probe result
    // causes, and it would report a check that RAN as one that never happened.
    @Test func nilIsTheOnlyWayToTheUncheckedRoute() {
        #expect(ContactRoute(probeResult: nil) == .unchecked)
        for result in Self.allProbeResults {
            #expect(ContactRoute(probeResult: result) != .unchecked,
                    "a probe result that really ran is being scored as if nobody asked")
        }
    }

    // The other direction: no route may be unreachable. A route nothing can produce is a value the
    // score branches on and no code path ever writes, which reads as a real answer and never is (L90).
    @Test func noContactRouteIsUnreachable() {
        var produced = Set(Self.allProbeResults.map { ContactRoute(probeResult: $0) })
        produced.insert(ContactRoute(probeResult: nil))
        #expect(produced == Set(ContactRoute.allCases),
                "a ContactRoute exists that no probe result and no absent probe can produce")
    }

    // MARK: the badge the row shows

    // Same rule on the third spelling. A `default:` in `badge(result:)` would put a new verdict's show
    // under a sentence describing a finding the check never made, which is L11 in a new place.
    @Test func everyProbeResultGetsItsOwnBadge() {
        let badges = Self.allProbeResults.map { Self.freshBadge(for: $0) }
        #expect(Set(badges).count == Self.allProbeResults.count,
                "two probe results share one Badge, so the row says the same thing about both")
    }

    // A probe that ran has an answer, so it must never produce the badge that means "say nothing" or the
    // one that means "this answer may be out of date". Both are states about the ABSENCE of a current
    // answer, and either is where a `default:` would most plausibly send a case nobody handled.
    @Test func aFreshProbeNeverRendersAsSilenceOrStaleness() {
        for result in Self.allProbeResults {
            let badge = Self.freshBadge(for: result)
            #expect(badge != Reachability.Badge.none,
                    "a check that ran and concluded something is rendering as a row with no answer")
            #expect(badge != .staleProbe,
                    "a fresh probe result is rendering as one past the freshness window")
        }
    }

    // Every badge must be reachable, through a real call rather than an assertion about the code. The
    // four non-probe states each have their own documented path, and this walks all of them: a stale
    // answer (#1325), a check that came home with nothing for this row (#1724), the free heuristic's
    // measured dead end (#1859), and its silence when it has nothing worth saying.
    //
    // A badge case added later and wired to nothing fails here, which is the half a mapping test cannot
    // see: the compiler never complains about a case nothing produces.
    @Test func noBadgeIsUnreachable() {
        var produced = Set(Self.allProbeResults.map { Self.freshBadge(for: $0) })

        produced.insert(Reachability.badge(result: .emailFound, probeIsStale: true,
                                           presenter: "A Presenting Organisation",
                                           sourceListingURL: "https://example.org/listing"))
        produced.insert(Reachability.badge(result: nil, missedByACheck: true,
                                           presenter: "A Presenting Organisation",
                                           sourceListingURL: "https://example.org/listing"))
        produced.insert(Reachability.badge(result: nil,
                                           presenter: "A Presenting Organisation",
                                           sourceListingURL: "https://instagram.com/anact"))
        produced.insert(Reachability.badge(result: nil,
                                           presenter: "A Presenting Organisation",
                                           sourceListingURL: "https://example.org/listing"))

        #expect(produced == Set(Reachability.Badge.allCases),
                "a Badge exists that no call into Reachability.badge can produce")
    }

    // The four paths above are only honest if each really produces the state it is there to produce, so
    // each is named. Without this the previous test could pass on four calls that all landed elsewhere.
    @Test func eachNonProbeBadgeComesFromItsOwnPath() {
        #expect(Reachability.badge(result: .emailFound, probeIsStale: true,
                                   presenter: "A Presenting Organisation",
                                   sourceListingURL: "https://example.org/listing") == .staleProbe)
        #expect(Reachability.badge(result: nil, missedByACheck: true,
                                   presenter: "A Presenting Organisation",
                                   sourceListingURL: "https://example.org/listing") == .checkMissedIt)
        #expect(Reachability.badge(result: nil,
                                   presenter: "A Presenting Organisation",
                                   sourceListingURL: "https://instagram.com/anact") == .hardToReach)
        #expect(Reachability.badge(result: nil,
                                   presenter: "A Presenting Organisation",
                                   sourceListingURL: "https://example.org/listing") == Reachability.Badge.none)
    }

    // MARK: the two mappings agreeing with each other

    // Both mappings must group the four verdicts the same way. Each on its own can be injective while
    // the pair disagrees, if one mapping later merges two verdicts the other keeps apart: the row would
    // then say one thing about two shows the score treats differently, and neither test above would
    // notice, because each only ever looks at one spelling.
    @Test func theRouteAndTheBadgeAgreeAboutWhichVerdictIsWhich() {
        for first in Self.allProbeResults {
            for second in Self.allProbeResults where first != second {
                let sameRoute = ContactRoute(probeResult: first) == ContactRoute(probeResult: second)
                let sameBadge = Self.freshBadge(for: first) == Self.freshBadge(for: second)
                #expect(sameRoute == sameBadge,
                        "the score and the row disagree about whether two probe results are the same thing")
            }
        }
    }
}
