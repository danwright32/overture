import Testing
import Foundation

// #2925: has `no_route_found` actually been adopted by real runs, and how often does the refusal fire?
//
// #2893 shipped the value a contact run uses to say it found a person and no way to reach them, plus a
// boundary check reporting a show whose contacts name a route and supply none. The new empty reason
// exists to catch a run MISBEHAVING, so it has to be rare: if runs keep naming `form_or_dm` on somebody
// with no route, the reason fires on ordinary shows, the card tells Dan a check fell short when it did
// what it always did, and the line gets ignored and then removed (L93).
//
// The instruction's only writer is a prompt, and the absence of the value is a legitimate answer
// everywhere else, so a run that ignored the instruction and a run with no name-only contact to report
// are indistinguishable from any one file (L128, L27). Only counting across real runs separates them.
//
// Both numbers come from the app's OWN predicate, `Reachability.declaredRouteIsMissing`, never a query
// written beside it: an ad-hoc reimplementation is a second definition that drifts, in the direction
// that flatters the argument being made (L107).
//
// This REPORTS rather than asserts a threshold. There is no number yet that says "adopted enough", and
// inventing one would be a bar nobody chose. What it does assert is that it measured something, and that
// it never presents PRE-CHANGE runs as evidence about a value that did not exist when they ran.
//
// Measured 2026-08-21, the first time anybody asked: across 17 real results files and 229 contacts,
// `no_route_found` appears ZERO times and the refusal fires on 12 shows. Both numbers are entirely
// pre-change: #2893 shipped at 2026-08-17 20:58 Eastern, and every results file on this Mac was written
// before then (the newest is the check at 13:50 that same day). So the question #2925 asks is still open
// rather than answered badly, and the 12 refusals are runs doing exactly what the runbook asked of them
// at the time. Run this again after the next contact check.
@Suite("How often real runs use no_route_found, and how often the refusal fires (#2925)")
struct NoRouteFoundAdoptionMeasurementTests {

    // When #2893 shipped, in Eastern time. A run before this could not have used a value that did not
    // exist, so counting it as a failure to adopt would be reading the old behaviour as the new defect
    // (L130: a fixture whose meaning is a relationship to a date has to pin both ends).
    private static let valueShippedAt = ISO8601DateFormatter().date(from: "2026-08-18T00:58:29Z")!

    private struct Census {
        var files = 0
        var runs: [NoRouteFoundAdoption.Run] = []
        var perRun: [String] = []
        var contacts = 0
        var noRouteFound = 0
        var routeNamedButNotSupplied = 0
        var showsRefused = 0
        var byMethod: [String: Int] = [:]
    }

    // #2895: the walk moved to `RealResultsFiles` when a second measurement needed the same set of
    // files. Unchanged, and shared rather than copied, so two measurements cannot read different runs.
    private func census() -> Census {
        var c = Census()
        for url in RealResultsFiles.urls() {
            guard let data = try? Data(contentsOf: url),
                  let results = try? PrepResultsDecoder.decode(data) else { continue }
            c.files += 1
            var runContacts = 0, runNoRoute = 0, runRefused = 0
            for result in results.results {
                let contacts = result.contacts ?? []
                var refused = false
                for contact in contacts {
                    c.contacts += 1
                    c.byMethod[contact.method ?? "(none)", default: 0] += 1
                    if contact.method == ContactMethod.noRouteFound.rawValue { c.noRouteFound += 1 }
                    if Reachability.declaredRouteIsMissing(contact) {
                        c.routeNamedButNotSupplied += 1
                        refused = true
                    }
                }
                if refused { c.showsRefused += 1; runRefused += 1 }
                runContacts += contacts.count
                runNoRoute += contacts.filter { $0.method == ContactMethod.noRouteFound.rawValue }.count
            }
            // #2893 shipped on 2026-08-17, and the runbook asked for `form_or_dm` on a name-only contact
            // until then. A run from before that date cannot have adopted a value that did not exist, so
            // the counts are kept per run and dated: a total that mixed the two would report the old
            // behaviour as a failure to adopt (L133 is the same shape).
            let day = url.deletingLastPathComponent().lastPathComponent
            let written = RealResultsFiles.writtenAt(url)
            let after = written >= Self.valueShippedAt
            c.runs.append(NoRouteFoundAdoption.Run(label: day.isEmpty ? "live" : day,
                                                   contacts: runContacts, noRouteFound: runNoRoute,
                                                   showsRefused: runRefused, writtenAt: written))
            c.perRun.append("\(day.isEmpty ? "live" : day): \(runContacts) contacts, "
                            + "\(runNoRoute) no_route_found, \(runRefused) shows refused"
                            + (after ? "  (since the value shipped)" : ""))
        }
        return c
    }

    @Test func countBothAcrossEveryRealRunOnThisMac() throws {
        let c = census()

        // Measured nothing is its own outcome, never a reassuring zero: every count below would read as
        // "runs are behaving" on a machine that simply has no runs to read (L98).
        guard c.files > 0, c.contacts > 0 else {
            Issue.record(Comment(rawValue: "no real results file on this machine carried a contact, so "
                                 + "these counts measure nothing. Files read: \(c.files)."))
            return
        }

        let methods = c.byMethod.sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        // Printed rather than asserted against a threshold: the point is the trend, and nobody has chosen
        // a number that means "adopted".
        print("""
              #2925 census over \(c.files) real results files, \(c.contacts) contacts:
                no_route_found:            \(c.noRouteFound)
                routeNamedButNotSupplied:  \(c.routeNamedButNotSupplied) contacts, \
              on \(c.showsRefused) shows
                methods:                   \(methods)
              files written since the value shipped: \(c.runs.filter { $0.writtenAt >= Self.valueShippedAt }.count)
              verdict: \(NoRouteFoundAdoption.verdict(runs: c.runs, shippedAt: Self.valueShippedAt))
              per run, oldest first (the value shipped 2026-08-17 20:58 Eastern):
              \(c.perRun.sorted().map { "    " + $0 }.joined(separator: "\n"))
              """)

        // The verdict comes from `NoRouteFoundAdoption`, shared with the suite that drives it on runs
        // this Mac does not have. One rule, so the live census and its own tests cannot disagree about
        // what the numbers mean (L16).
        let verdict = NoRouteFoundAdoption.verdict(runs: c.runs, shippedAt: Self.valueShippedAt)

        // Nothing since the value shipped is the state on 2026-08-21, and it is a FACT about this Mac
        // rather than a defect: said out loud and not failed, because failing would hold every merge
        // hostage to Dan running a contact check.
        if verdict == .nothingToJudgeYet {
            print("  NOTHING TO JUDGE YET: no results file written since the value shipped carried a "
                  + "contact, so every count above predates it and says nothing about adoption.")
            return
        }

        #expect(verdict != .firingOnTheOrdinaryCase,
                Comment(rawValue: "since the value shipped, the route-named-but-not-supplied refusal is "
                        + "firing on the ordinary case rather than on a misbehaving run. Either the runs "
                        + "have not adopted no_route_found, or the refusal is wrong. \(c.perRun)"))
    }
}
