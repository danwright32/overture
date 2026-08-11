import Testing
import Foundation

// #2365: the ambient facts every stage question is asked against, carried as ONE value.
//
// This suite pins the two things the bundling exists to buy, both of which are defects in the
// three-loose-arguments shape rather than matters of taste.
//
// ONE CLOCK. `today` and `now` are two spellings of the same instant, and while they were separate
// arguments a caller could pass a date derived from one clock beside a time taken from another, with
// nothing able to notice. Deriving `today` from `now` inside the value makes the disagreement
// unrepresentable rather than merely unlikely.
//
// NOTHING DEFAULTS TO OFF AT A CALL SITE. #901 records what a defaulted gate costs here in its own
// words: the Prep pill forgot the conflict gate because forgetting it was invisible, so it counted a
// show the Prep run then refused. `geo` defaulting to `.none` is the same shape, because a surface
// that should have applied Dan's geography refusals and did not looks identical to one that had none.
@Suite("Every stage question is asked against one context (#2365)")
struct StageContextTests {

    // 2026-08-11 19:30 UTC is 15:30 in New York on the same day: an hour where the two zones agree,
    // so this case isolates the ordinary derivation from the boundary case below.
    static let afternoon = Date(timeIntervalSince1970: 1_786_476_600)

    @Test("today is derived from now, so the two cannot disagree")
    func todayIsDerivedFromNow() {
        let context = StageContext(now: Self.afternoon, geo: .none)
        #expect(context.today == EasternDate.today(Self.afternoon))
        #expect(context.now == Self.afternoon)
    }

    // The case that makes the derivation worth having. At 02:00 UTC on 12 August it is still 22:00 on
    // 11 August in New York, so a `today` taken from any other zone names a day Overture never uses.
    // Overture's whole date vocabulary is Eastern (#177), and a queue window judged a day early drops
    // a show Dan could still pitch.
    @Test("the derived day is Overture's Eastern day, not the host's")
    func theDerivedDayIsEastern() {
        let lateUTC = Date(timeIntervalSince1970: 1_786_500_000)   // 2026-08-12 02:00 UTC
        let context = StageContext(now: lateUTC, geo: .none)
        #expect(context.today == "2026-08-11")
    }

    // The one seam a test needs: pin the day without having to work backwards to an instant that
    // produces it. Production never uses this, and `noProductionCallSitePinsTheDay` below is what
    // holds that true rather than a comment saying so.
    @Test("a test may pin the day explicitly")
    func aTestMayPinTheDay() {
        let context = StageContext(now: Self.afternoon, geo: .none, today: "2027-01-15")
        #expect(context.today == "2027-01-15")
        #expect(context.now == Self.afternoon)
    }

    // #1962 gave GeoRefusals a memo of resolved places and made its Equatable deliberately blind to it,
    // because one of these values is read as a render fingerprint and a derived difference there
    // reports as a change nobody made. Wrapping it must not undo that.
    @Test("two contexts carrying the same refusals are equal even when one has done the work")
    func equalityIgnoresTheResolvedMemo() {
        let refusals = GeoRefusals(userExcludedTowns: ["philadelphia"])
        let fresh = StageContext(now: Self.afternoon, geo: refusals)
        let worked = StageContext(now: Self.afternoon, geo: refusals.resolving([]))
        #expect(fresh == worked)
    }

    @Test("contexts differing in any of their facts are not equal")
    func inequalityHoldsOnEveryFact() {
        let base = StageContext(now: Self.afternoon, geo: .none)
        #expect(base != StageContext(now: Self.afternoon.addingTimeInterval(86_400 * 3), geo: .none))
        #expect(base != StageContext(now: Self.afternoon, geo: .none, today: "2027-01-15"))
        #expect(base != StageContext(now: Self.afternoon,
                                     geo: GeoRefusals(userExcludedTowns: ["philadelphia"])))
    }

    // The memo step must not quietly undo the pin. Re-deriving the day there would look harmless (it
    // agrees with `now` in production) and would silently discard exactly the day a caller went out of
    // its way to set, which is the one thing a caching step may never do.
    @Test("resolving places keeps the day and the instant the context was built with")
    func resolvingPlacesKeepsTheClock() {
        let pinned = StageContext(now: Self.afternoon, geo: .none, today: "2027-01-15")
        let resolved = pinned.resolvingPlaces(of: [])
        #expect(resolved.today == "2027-01-15")
        #expect(resolved.now == Self.afternoon)
    }

    // The guard that makes the derivation real rather than merely available. If any shipping call site
    // pins the day by hand, the one-clock property above is true of the type and false of the app.
    //
    // Scoped to each CONSTRUCTION's own arguments, never to the file. `today:` is an ordinary label all
    // over these files (it is half of `StageNavigation`'s old signature and most of `EasternDate`'s), so
    // a file-wide `contains("today:")` would fail on files that never build a context at all, and a
    // guard that is red for an unrelated reason gets read as noise and then silenced (L103).
    @Test("no production call site pins the day by hand")
    func noProductionCallSitePinsTheDay() {
        var constructionsChecked = 0
        for file in Self.appFilesBuildingAContext {
            let source = Self.code(in: SourceGuardHelper.source(file))
            for arguments in Self.constructionArguments(in: source) {
                constructionsChecked += 1
                #expect(!arguments.contains("today:"), Comment(rawValue:
                    "\(file) pins the day by hand: StageContext(\(arguments)). Production must let the "
                    + "context derive Overture's day from its own instant."))
            }
        }
        // L98/L100: finding nothing to check is not a pass. If the app stops building contexts in these
        // files (a rename, a move, a file split), this guard would otherwise report green while checking
        // nothing at all, which is indistinguishable from every call site being correct.
        #expect(constructionsChecked > 0,
                "found no StageContext construction in any listed app file, so this guard checked nothing")
    }

    // Comments and string literals stripped, so a construction discussed in prose or quoted inside
    // another guard's expected text is not read as a call site (L103).
    static func code(in source: String) -> String {
        SwiftSource.scannableLines(in: source, skipping: []).map(\.code).joined(separator: "\n")
    }

    // The argument text of every `StageContext(` call in `source`, read by balancing parentheses rather
    // than to the next `)`, so a nested call in an argument cannot end the scan early.
    static func constructionArguments(in source: String) -> [String] {
        var found: [String] = []
        var search = source.startIndex
        while let call = source.range(of: "StageContext(", range: search..<source.endIndex) {
            var depth = 1
            var index = call.upperBound
            while index < source.endIndex, depth > 0 {
                if source[index] == "(" { depth += 1 }
                if source[index] == ")" { depth -= 1 }
                if depth > 0 { index = source.index(after: index) }
            }
            if depth == 0 { found.append(String(source[call.upperBound..<index])) }
            search = index < source.endIndex ? source.index(after: index) : source.endIndex
        }
        return found
    }

    static let appFilesBuildingAContext = [
        "Overture/UI/QueueView.swift",
        "Overture/UI/QueueRenderPass.swift",
        "Overture/App/RootView.swift",
        "Overture/Domain/AgentRoster.swift",
        "Overture/Domain/StageOverlap.swift",
        "Overture/Domain/VenuePlaceAnswer.swift",
    ]
}
