import Testing
import Foundation

// #2955: the checked-in sample drafts are read as examples of what a good draft looks like, so a sample
// showing a rule that has since been REVERSED teaches the reversed rule.
//
// Three had gone stale. One stated the rate in a cold pitch, which Dan reversed on 2026-07-31 ("they may
// check out my portfolio instead of getting sticker shock"). Three linked a gallery path the site keeps
// but a draft may not name, which #1832 retired on 2026-07-30 and which the app now REFUSES to send
// (`DraftCheck.galleryPathLink` is blocking). One closed on "Let me know how that lands", which Dan
// rejected on 2026-07-18. So the corpus held bodies the product itself would block.
//
// This enumerates whatever is committed rather than naming the three files, so a sample added later is
// held to the same rules without anybody remembering to add it here (L96).
@Suite("A checked-in sample draft follows the rules that are current (#2955)")
struct SampleDraftsFollowCurrentRulesTests {
    private struct Sample {
        let file: String
        let body: String
    }

    // Every `draft.body` in every committed prep-results fixture, with the file it came from so a failure
    // names what to open. Decoded loosely on purpose: this is about the TEXT, and a fixture pinned to an
    // older schema version must still be held to the copy rules.
    private func samples() throws -> [Sample] {
        let dir = RepoRoot.url.appendingPathComponent("fixtures/prep-results")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        var found: [Sample] = []
        for name in names {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let json = try JSONSerialization.jsonObject(with: data)
            for body in Self.draftBodies(in: json) {
                found.append(Sample(file: name, body: body))
            }
        }
        return found
    }

    private static func draftBodies(in json: Any) -> [String] {
        if let dict = json as? [String: Any] {
            var bodies: [String] = []
            for (key, value) in dict {
                if key == "body", let body = value as? String { bodies.append(body) }
                else { bodies.append(contentsOf: draftBodies(in: value)) }
            }
            return bodies
        }
        if let list = json as? [Any] { return list.flatMap { draftBodies(in: $0) } }
        return []
    }

    // The corpus is not empty, asserted first. Every check below passes vacuously over no samples, and an
    // empty corpus is what a moved directory or a changed field name looks like (L98).
    @Test func thereAreSampleDraftsToJudge() throws {
        #expect(try samples().count >= 3)
    }

    // The rule the app ENFORCES. A sample that could not be sent is the sharpest version of this defect:
    // it is not merely out of date, it demonstrates output the product refuses.
    @Test func noSampleWouldBeBlockedAtSend() throws {
        for sample in try samples() {
            let blockers = DraftCheck.blockingFindings(in: sample.body)
            let refused = "\(sample.file) holds a sample the app would refuse to send: "
                + blockers.map(\.label).joined(separator: ", ")
            #expect(blockers.isEmpty, Comment(rawValue: refused))
        }
    }

    // A cold pitch carries no rate and no turnaround (Dan, 2026-07-31, reversing the rule that made the
    // rate mandatory). DraftCheck cannot catch this, because $250 IS the canonical rate and the check
    // exists to catch a DIFFERENT number: what is wrong here is stating one at all.
    @Test func noSampleStatesARateOrATurnaround() throws {
        for sample in try samples() {
            #expect(!sample.body.contains("$"),
                    "\(sample.file) states a price in a cold pitch, which was reversed on 2026-07-31")
            #expect(!sample.body.lowercased().contains("within two weeks"),
                    "\(sample.file) promises a turnaround, which a cold pitch does not carry")
        }
    }

    // A pitch that asks for nothing is not a pitch (#1889, #2531). The samples are what the runbook
    // points the drafting run at, so a sample that only admires the show demonstrates the one failure
    // the ask rule exists to stop. Asserted through the app's own matcher rather than a phrase list,
    // because the runbook tells the run to reword the ask every time.
    @Test func everySampleAsksAboutTheirPhotographyPlans() throws {
        for sample in try samples() {
            #expect(DraftCheck.asksAboutPhotographyPlans(sample.body),
                    Comment(rawValue: "\(sample.file) holds a sample that requests nothing"))
        }
    }

    // The retired close. Dan flagged it on 2026-07-18 as sounding douchey, and the runbook names it
    // explicitly, so a sample still using it is teaching the sentence the runbook forbids.
    @Test func noSampleUsesARetiredClose() throws {
        for sample in try samples() {
            let lower = sample.body.lowercased()
            #expect(!lower.contains("how that lands"),
                    "\(sample.file) uses the close Dan rejected on 2026-07-18")
            #expect(!lower.contains("happy to answer any questions"),
                    "\(sample.file) uses the close retired on 2026-07-31")
        }
    }
}
