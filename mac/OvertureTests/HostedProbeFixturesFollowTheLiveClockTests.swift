import Testing
import Foundation

// #3169: a probe instant in a HOSTED test must not be one the live clock is about to walk past.
//
// The hosted target renders real SwiftUI views. `ProspectRowView` asks `item.reachabilityBadge()` and
// `Reachability.recheckState` with no `now`, so both read the wall clock at render time and a hosted test
// has no seam to pin the other end of the pair with. A fixture written as a fixed instant therefore means
// "probed on that day" while the test means "probed recently", and the two agree only until real time
// walks past `Reachability.probeFreshness`.
//
// It walked past it at 2026-08-26T20:26:40Z. Thirteen tests, eight in `ProspectRowViewReachabilityTests`
// and five in `RecheckControlOnTheRowTests`, went red at once on a main nobody had touched, because every
// row had begun rendering `staleProbeBadge` instead of the badge each test asserts.
// `CardAddressAttributionOnScreenTests` carried the identical fixture and stayed green only because it
// asserts on the address list, which renders whatever the badge says: the same rot with a later fuse.
//
// Neither existing tool could see it coming, which is why this is a guard rather than a note.
// `check-fixtures-do-not-age.sh` shifts fixtures FORWARD, which turns a past probe into a future one and
// leaves `probeIsStale` answering false on both sides, so the verdict never changed and the fixture never
// entered `fixtures/year-sensitive-tests.txt`. `check-far-future-fixtures.sh` pulls FAR dates back, and
// 2026-05-28 is not far. Real time passing is a fixture moving BACKWARD, and nothing shifts that way
// (#3170).
//
// WHAT IT MEASURES, which is the part to read before changing it. Not "is this instant written as a
// literal", which is the obvious rule and the wrong one: `ReachabilityProbeControlTests` deliberately
// pins 1970 to mean "long expired", and an instant that is already far outside the window can never
// re-enter it, so it is settled and asserts the same thing forever. What ticks is an instant currently
// INSIDE the window, because that is the one with a date on it when it changes meaning. So the guard
// computes the fixture's age against the live clock and the app's own `probeFreshness`, and fires on the
// ones still counting down. On the fixtures this repo carried, it would have been red every day from
// 2026-05-28 to the morning the suite went red, and green on all four of the pinned instants that were
// never going to move.
//
// This suite therefore reads the wall clock on purpose, and `check-fixtures-do-not-age.sh` will report it
// as a new year-sensitive entrant the next time that is run. That is correct rather than a defect to fix:
// a guard about what the clock does to a fixture cannot be blind to the clock.
//
// The fields are DERIVED from the app rather than listed here, because a hand-written registry only ever
// checks what somebody remembered and would be one field out of date the first time a new one is judged
// against a window (L96). They are whatever the app passes as `probedAt:` to the two functions that
// compare a stored instant against a clock.
@Suite("A hosted test's probe instant is not one the clock is about to outrun (#3169)")
struct HostedProbeFixturesFollowTheLiveClockTests {

    // MARK: - The detector, as pure functions

    // Every name the app hands to a freshness comparison, with any receiver (`i.`, `item.`, `answer.`)
    // stripped, so what comes back is the FIELD rather than the expression that reached it.
    static func fieldsJudgedAgainstAClock(in appSource: String) -> Set<String> {
        var out: Set<String> = []
        for call in ["probeIsStale(probedAt: ", "recheckState(probedAt: "] {
            var rest = Substring(appSource)
            while let hit = rest.range(of: call) {
                let argument = rest[hit.upperBound...]
                    .prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
                if let name = argument.split(separator: ".").last, !name.isEmpty {
                    out.insert(String(name))
                }
                rest = rest[hit.upperBound...]
            }
        }
        return out
    }

    // Every instant a file pins, as seconds since 1970, with its line. Read over the whole file rather
    // than per assignment, deliberately: the real incident bound its instant to a `private let` and
    // assigned THAT to the field, one sibling writes the pair on a single line after a semicolon, and a
    // rule reading only assignment lines passed both. What narrows it back down is the age test below,
    // which is a measurement rather than a guess about what a line is for.
    static func pinnedInstants(in source: String) -> [(line: String, at: Date)] {
        var out: [(String, Date)] = []
        for line in source.components(separatedBy: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
            var rest = Substring(code)
            while let hit = rest.range(of: "Date(timeIntervalSince1970: ") {
                let digits = rest[hit.upperBound...].prefix { $0.isNumber || $0 == "_" }
                if let seconds = TimeInterval(digits.replacingOccurrences(of: "_", with: "")) {
                    out.append((code, Date(timeIntervalSince1970: seconds)))
                }
                rest = rest[hit.upperBound...]
            }
        }
        return out
    }

    // A pinned instant is ticking while the live clock has not yet carried it out of the window: only
    // then can it change what the fixture means. A future instant counts, since the clock reaches it and
    // then keeps going.
    static func stillCountingDown(_ at: Date, now: Date, window: TimeInterval) -> Bool {
        now.timeIntervalSince(at) <= window
    }

    // MARK: - The detector was seen to find the shape, and not to fire on the settled one

    @Test func findsAnInstantTheClockHasNotFinishedWith() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)   // 115 days past the fixture below
        let window: TimeInterval = 90 * 24 * 60 * 60

        // The real fixture, on a day before it crossed.
        #expect(Self.stillCountingDown(Date(timeIntervalSince1970: 1_780_000_000),
                                       now: Date(timeIntervalSince1970: 1_782_000_000), window: window))
        // The same fixture after the crossing: settled, and it asserts the same thing forever now.
        #expect(!Self.stillCountingDown(Date(timeIntervalSince1970: 1_780_000_000), now: now, window: window))
        // 1970, which is what a fixture pinned to mean "long expired" looks like.
        #expect(!Self.stillCountingDown(Date(timeIntervalSince1970: 1_000_000), now: now, window: window))
        // Ahead of the clock, which is the same countdown with further to run.
        #expect(Self.stillCountingDown(Date(timeIntervalSince1970: 1_795_000_000), now: now, window: window))
    }

    @Test func readsEveryPinnedInstantIncludingTheOnesAnAssignmentRuleMisses() {
        let found = Self.pinnedInstants(in: """
        struct SomethingTests {
            private let probedAt = Date(timeIntervalSince1970: 1_780_000_000)
            func item() {
                var stale = item("s"); stale.reachabilityProbedAt = Date(timeIntervalSince1970: 1_000_000)
                // A comment quoting Date(timeIntervalSince1970: 42) is prose, not a fixture.
            }
        }
        """)
        #expect(found.map(\.at.timeIntervalSince1970).sorted() == [1_000_000, 1_780_000_000])
    }

    // MARK: - The live claim

    // Derived from the app. A derivation that came back empty would make every file below pass over
    // nothing, which is the emptiest possible failure reading as the cleanest possible pass (L98).
    static var judgedFields: Set<String> {
        fieldsJudgedAgainstAClock(in: AppSourceWalk.appFiles().map(\.text).joined(separator: "\n"))
    }

    @Test func theFieldListIsDerivedFromTheAppAndNamesTheFieldsAClockJudges() {
        let fields = Self.judgedFields
        #expect(fields.contains("reachabilityProbedAt"))
        #expect(fields.contains("reachabilityUnansweredAt"))
    }

    @Test func noHostedProbeFixtureIsStillCountingDown() {
        let fields = Self.judgedFields
        #expect(!fields.isEmpty)
        let now = Date()
        let window = Reachability.probeFreshness
        let hosted = AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("OvertureHostedTests"),
                                         floor: 30)
        var offenders: [String] = []
        for file in hosted where fields.contains(where: { file.text.contains($0) }) {
            for pinned in Self.pinnedInstants(in: file.text)
            where Self.stillCountingDown(pinned.at, now: now, window: window) {
                offenders.append("\(file.name): \(pinned.line)")
            }
        }
        #expect(offenders.isEmpty, """
            These hosted fixtures pin an instant the live clock has not finished with, in a file whose \
            fixtures feed a freshness window the view reads at render time. That is #3169 about to happen \
            again: the fixture stops meaning what it says on a date nobody chose, and the suite goes red \
            on a main nobody touched. Use LiveClockProbe.fresh or LiveClockProbe.stale, which are derived \
            from Reachability.probeFreshness and therefore never cross anything.
            \(offenders.joined(separator: "\n"))
            """)
    }
}
