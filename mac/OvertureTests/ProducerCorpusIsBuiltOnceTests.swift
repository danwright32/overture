import Testing
import Foundation

// #3238: nothing asks `ProducerGate.qualifies(_:among:)` inside a loop.
//
// That overload's whole body is `qualifies(presenter, in: Corpus(shows), overrides:)`, so it rebuilds an
// index of every show on every call. Asked once, that is the convenience it was written to be. Asked per
// organisation key, or per show, it is a full pass over the store per row, which is a quadratic hiding
// behind an argument label.
//
// It had happened twice. `OrganisationListing.build` asked it per organisation key, and
// `ProbeBatch` asked it per picked show, while `OrgAnswerLedger` beside them had used the `in:` form
// since #1965, which is when the corpus was extracted for exactly this reason. Measured on the live
// store, 1,018 shows: `OrganisationListingLiveStoreTests` took 23.433 seconds before and 2.776 after,
// and that is the Organisations sheet's own cost as much as the test's, since `OrganisationsSheetModel`
// runs the same function to draw it.
//
// Guarded by SOURCE rather than by a counter, deliberately. A `buildsPerformed` counter on `Corpus`
// would be a mutable process-wide static in the app target, which is the shape `check-test-shared-state.sh`
// exists to keep out of the test targets and is no better one field over (#3270). The shape here is
// visible in the text and the text is where it went wrong.
@Suite("The producer corpus is built once per listing, not once per row (#3238)")
struct ProducerCorpusIsBuiltOnceTests {

    // Every app source file, so a third call site written next year is covered by a guard it never heard
    // of rather than by a list holding whatever somebody remembered (L96).
    @Test func noAppCodeAsksTheCorpusRebuildingOverloadInsideALoop() throws {
        let files = AppSourceWalk.appFiles()
        #expect(files.count > 100, "walked \(files.count) app files, which is a broken path rather than a small app")

        var offenders: [String] = []
        var examined = 0

        for file in files {
            let lines = file.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("qualifies(") && line.contains("among:") {
                // A line that only TALKS about the overload is not a call to it.
                let code = line.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
                guard code.contains("among:") else { continue }
                examined += 1
                // Inside a loop, judged by scanning BACKWARD to the nearest loop or function keyword
                // rather than by a fixed window of lines, which is answered by whatever happens to sit
                // inside it (L518).
                var back = index
                while back > 0 {
                    back -= 1
                    let candidate = lines[back].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix("//") { continue }
                    if candidate.hasPrefix("for ") || candidate.hasPrefix("while ")
                        || candidate.contains(".map {") || candidate.contains(".filter {")
                        || candidate.contains(".contains {") || candidate.contains(".first {") {
                        offenders.append("\(file.name):\(index + 1)")
                        break
                    }
                    if candidate.hasPrefix("func ") || candidate.hasPrefix("static func ") { break }
                }
            }
        }

        // Zero call sites examined would make this pass by finding nothing to judge, which is the same
        // empty answer a clean app gives (L98). The overload still exists and the tests still use it, so
        // a corpus of zero here means the search stopped matching rather than that the app stopped
        // calling it. Asserted against the APP only, where the count is currently zero by design, so the
        // floor is on the WALK rather than on the hits.
        #expect(offenders.isEmpty, """
            These ask ProducerGate.qualifies(_:among:) inside a loop, which rebuilds the whole corpus on \
            every iteration: \(offenders.joined(separator: ", ")). Build a ProducerGate.Corpus once \
            outside the loop and ask qualifies(_:in:) instead, as OrganisationListing.build and \
            ProbeBatch now do.
            """)
    }

    // The mirror, so the guard above cannot be satisfied by the overload having quietly disappeared: it
    // is still there, still the convenience it was written to be, and still correct for a single ask.
    @Test func theConvenienceOverloadStillExistsForASingleAsk() {
        let shows = [
            ProducerGate.Show(presenter: "Parkside Chamber Players", venue: "A Hall"),
            ProducerGate.Show(presenter: "Parkside Chamber Players", venue: "B Hall"),
        ]
        #expect(ProducerGate.qualifies("Parkside Chamber Players", among: shows))
        // And it agrees with the corpus form, which is what makes swapping one for the other safe.
        let corpus = ProducerGate.Corpus(shows)
        #expect(ProducerGate.qualifies("Parkside Chamber Players", in: corpus)
                == ProducerGate.qualifies("Parkside Chamber Players", among: shows))
    }
}
