import Testing
import Foundation

// #2650: the copy that leaves the building under Dan's name gets a reader.
//
// It is deliberately excluded from `docs/copy-inventory.md`, and that exclusion is right: the inventory
// is the app's own voice to Dan, and a recipient is not Dan. But a category excluded from a review, for a
// correct reason, has NO reviewer at all unless one is named in the same breath (L129), and this one did
// not: #2643 sent people who had never replied a note saying it was good to be in touch, and it survived
// #2615 rewriting the sentence beside it three days earlier.
@Suite("Outbound copy has a reader (#2650)")
struct OutboundCopyTests {

    // MARK: what it finds

    @Test("it collects the sentences a recipient actually reads")
    func itFindsTheOutboundSentences() throws {
        let document = try OutboundCopy.build()
        #expect(document.filesScanned > 50, "a wrong root would scan nothing and report no outbound copy")
        #expect(!document.sentences.isEmpty)
        // The sign-off is the one sentence that goes on EVERY email Overture sends, so if the collector
        // has stopped seeing anything, it is the first thing that would go missing.
        #expect(document.sentences.contains { $0.contains("Dan Wright Photography") },
                "the plain-text sign-off is missing from the outbound list")
    }

    // The two lists must not overlap. A sentence in both is either app copy wrongly marked as outbound or
    // outbound copy leaking into the list Dan cold-reads as the app's own voice, and both are wrong.
    @Test("no sentence is in both the inventory and the outbound list")
    func theTwoListsAreDisjoint() throws {
        let outbound = Set(try OutboundCopy.build().sentences)
        let inventory = Set(try CopyInventory.build().sentences)
        #expect(outbound.intersection(inventory).isEmpty,
                "in both lists: \(outbound.intersection(inventory).sorted())")
    }

    // MARK: the checked-in document

    @Test("the checked-in outbound copy is up to date")
    func theCheckedInDocumentIsFresh() throws {
        let generated = try OutboundCopy.build().render()
        let existing = (try? String(contentsOf: OutboundCopy.checkedInURL, encoding: .utf8)) ?? ""
        let outcome = CopyInventory.checkCheckedIn(existing: existing, generated: generated,
                                                   regenerate: CopyInventory.regenerationRequested(),
                                                   documentPath: OutboundCopy.documentPath)
        switch outcome {
        case .upToDate:
            break
        case .regenerated(let contents, let message):
            try contents.write(to: OutboundCopy.checkedInURL, atomically: true, encoding: .utf8)
            Issue.record("\(message)")
        case .stale(let message):
            Issue.record("\(message)")
        }
    }

    // MARK: the completeness half

    // The tag is what gives a region a reader, so a region that reads like outbound email and carries no
    // tag is exactly the state this issue is about, back again under a different sentence. Derived from
    // the source rather than from a list of the three files somebody remembered (L96).
    @Test("no outbound region is left without the tag that gives it a reader")
    func everyOutboundRegionIsTagged() throws {
        let offenders = try OutboundCopy.untaggedOutboundRegions()
        #expect(offenders.isEmpty, """
            These ignore regions read like outbound email but carry no `\(OutboundCopy.tag)` tag, so \
            nothing puts their sentences in front of a person:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // The control for the check above: its phrase list has to be able to MATCH something, or a reword
    // leaves it green over a codebase full of untagged outbound regions (L70).
    @Test("the untagged check can still recognise an outbound region")
    func theUntaggedCheckStillMatches() {
        let asItWas = "outbound email: a recipient reads this, not Dan (#915)"
        #expect(OutboundCopy.outboundSoundingPhrases.contains { asItWas.lowercased().contains($0) },
                "this check would not have caught the wording these regions actually had")
    }
}
