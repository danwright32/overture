import Testing
import Foundation

// #2554: on a rental room the individual billed as producing IS the person who hired the room and who
// would hire a photographer, and `ProducerShapedName` refused every one of them.
//
// Dan hit this on 2026-08-13 on "54 Sings Shuffle Along, Or... A 10th Anniversary Celebration" (54 Below,
// 2026-08-17). The listing text handed to the run says "this concert is produced and directed by Corin
// Hale", the run read that text (all 13 cast names came out of it), and it returned 13 contacts, every
// one of them `provenance: "performer"` and `tier: "secondary"`. Zero primary. She was one fetch away:
// corinhale.example/contact publishes her address. He found it himself in seconds and asked why the check
// had not.
//
// ## What was measured before writing this, and what it changed
//
// Dan's first instruction was to widen the rule generally and let the tier carry the difference: a name
// behind "produced by" primary, a bare name secondary. The calibration refuted the second half.
//
// The live VenueTix feed (thegreenroom42.venuetix.com), fetched 2026-08-13: 248 events, 148 distinct
// supertitles. Accepting a bare short capitalised name would have taken 19 of them and NOT ONE is a
// person: "One Night Only", "TikTok Star", "Viral Artist", "Solo Show Debut", "New Solo Show", "The
// Ringmaster", "Broadway's Superstar Couple". Meanwhile all four genuinely credit-bearing supertitles in
// the whole feed are refused today. So the credit is what carries the signal, and the bare shape carries
// none. Dan's call on being shown that: credit only, on both paths.
//
// ## The second thing the corpus said
//
// Widening the NAME rule alone would have taken a performer's PAST credits with it, which the runbook
// already warns the run about. Measured across the 23 listing texts in the prep run archives on this Mac,
// every "produced by" in them:
//
//   REAL, the show's own credit          FALSE, a credit inside a performer's bio
//   ". Produced by Amy Sapp"             "\"Ghouls Just Wanna Have Fun!\" produced by Moore Productions"
//   ". Produced by Gabrielle Karyss"     "a compilation produced by Tito Pingolinis"
//   ". Produced by Lindsay Wormser"
//   ". Produced and directed by Cate Elise Goddard"
//   "this concert is produced and directed by Corin Hale"
//
// The two halves are told apart by what the credit ATTACHES to, not by where it sits or how far in it is:
// the false ones hang off another work (a quoted show title, an album), the real ones off the show itself,
// as a new sentence or after a linking verb. That is the rule below. Note it makes the parse STRICTER for
// companies as well as wider for people: "produced by Moore Productions" is accepted today, from a bio,
// which is the same defect this refuses.
//
// A distance bound was considered and rejected. It would have worked on this corpus (real credits at 656
// to 1050 characters after the title, false ones at 1250 and 1555), and that is exactly the shape of a
// limit fitted to one snapshot and then treated as a contract (L48, L56).
@Suite("An individual billed as producing is a research target (#2554)")
struct IndividualBilledAsProducingTests {

    // The p0 case, verbatim from the run's own archived queue file.
    @Test func theCreditDanHitIsReadAsAProducer() {
        let prose = "Featuring an all-star cast, including select members from the 2016 original Broadway "
            + "production, this concert is produced and directed by Corin Hale (author of When "
            + "Broadway Was Black)."
        #expect(ProducerShapedName.billedInProse(prose) == "Corin Hale")
    }

    // The four other real credits in the archives, each the show's own, each an individual, each refused
    // before this change. Quoted as the pages spell them, `&nbsp;` and spaced full stops included.
    @Test("the show's own credit names its producer, whoever they are",
          arguments: [
            (". Produced by Amy Sapp . Music direction by Makai Keur .", "Amy Sapp"),
            // Two of these pages write a non-breaking space after the credit, so the fixtures carry the
            // `&nbsp;` the stored text really holds rather than a tidied version of it (L48). It is the
            // reason the rule normalises before matching: without that, the credit reads as "produced
            // by&nbsp;" and matches nothing, on the exact pages this feature exists for.
            ("musical numbers. Produced by&nbsp; Gabrielle Karyss , with music direction",
             "Gabrielle Karyss"),
            ("Music direction by&nbsp; Tracy Stark . Produced by&nbsp; Lindsay Wormser . Joined by:",
             "Lindsay Wormser"),
            ("and more. Produced and directed by Cate Elise Goddard . With associate producer",
             "Cate Elise Goddard"),
          ])
    func aRealCreditIsRead(_ pair: (String, String)) {
        #expect(ProducerShapedName.billedInProse(pair.0) == pair.1)
    }

    // The company case #2262 already handled keeps working, unchanged.
    @Test func aCreditedCompanyStillReads() {
        #expect(ProducerShapedName.billedInProse(
            "Produced by Productions by Stephan, Re-Arranged is a one-night-only celebration")
                == "Productions by Stephan")
    }

    // The two false positives from the same corpus, and the reason the attachment rule exists. The first
    // is accepted TODAY (the company words carry it), so this half is a fix, not only a guard against the
    // widening: a past credit in a performer's bio has never been who is producing tonight.
    @Test("a credit hanging off another work is not this show's producer",
          arguments: [
            "She made her TGR42 Debut on Halloween 2025, in \"Ghouls Just Wanna Have Fun!\" produced by "
                + "Moore Productions. Some of her most recent credits include",
            "Gogo's work is featured in a compilation produced by Tito Pingolinis and on an album with "
                + "artist Andy Ordonez.",
          ])
    func aPastCreditInABioIsRefused(_ prose: String) {
        #expect(ProducerShapedName.billedInProse(prose) == nil)
    }

    // The prose the issue named as the reason the rule was kept narrow: these are on the same pages and
    // none of them says who is producing tonight.
    @Test("ordinary prose is still not a credit",
          arguments: [
            "Hayley Trapp presents The Bubbling Cabaret",
            "the Showpeople Theatre Collective returns to New York City",
            "Developed with the historic Apollo Theater and Drama Club Camp Productions",
            "produced by the company that staged it",
          ])
    func proseIsNotACredit(_ prose: String) {
        #expect(ProducerShapedName.billedInProse(prose) == nil)
    }

    // The supertitle path reads the SAME rule, so a credit standing above the title is found by the one
    // definition rather than a second spelling of it (#2452, L89). Both of these are refused today.
    @Test("a credit in the supertitle is read by the same rule",
          arguments: [("Produced by Sullivan Roarke", "Sullivan Roarke"),
                      ("Directed & Produced by Océane Vireux", "Océane Vireux")])
    func aSupertitleCreditIsRead(_ pair: (String, String)) {
        #expect(ProducerShapedName.from(pair.0) == pair.1)
    }

    // And the 19 the bare-name widening would have taken. Every one is a marketing line from the live
    // VenueTix feed, and every one must still be refused: they name nobody, so each one accepted is a
    // research target that spends lookups on a phrase.
    @Test("a marketing supertitle is still not a producer",
          arguments: ["One Night Only", "TikTok Star", "Viral Artist", "New Solo Show", "The Ringmaster",
                      "Solo Show Debut", "Solo Cabaret Debut", "One Woman Musical", "Musical Theatre Pros",
                      "Broadway's Superstar Couple", "Broadways Brightest Lights", "An Appalachian Evening",
                      "From Powerhouse Cabarets", "From Solstice Serenades", "Lauryn Hill Hosts",
                      "The Second Annual", "YouTube's Fave", "Songs. Satire. Pigeons.",
                      "A SandboxMusicals Showcase"])
    func aMarketingSupertitleIsRefused(_ supertitle: String) {
        #expect(ProducerShapedName.from(supertitle) == nil)
    }

    // The supertitles the rule already accepted are untouched, so widening the credit did not move the
    // boundary the 2026-08-07 calibration set.
    @Test("the supertitles accepted before are accepted still",
          arguments: [("Acting Up Entertainment's", "Acting Up Entertainment"),
                      ("Jack and Friends'", "Jack and Friends"),
                      ("Track 29 Productions", "Track 29 Productions")])
    func anAlreadyAcceptedSupertitleIsUnchanged(_ pair: (String, String)) {
        #expect(ProducerShapedName.from(pair.0) == pair.1)
    }
}

// The calibration itself, against the whole live feed rather than against the handful of lines somebody
// thought to quote. `fixtures/venuetix-supertitles/2026-08-13.json` is the real thing, fetched through the
// same client feed the app reads: 248 events, 148 distinct supertitles.
//
// The rule's own history is why this is pinned rather than described. Its first version matched 34 of 141
// and was wrong on several; the second matched 25 and was right on all of them; the number and the
// examples then lived only in a comment, so the next person to touch it had nothing that could go red.
//
// What the boundary IS, measured: 28 accepted before this change, 30 after. The two added are exactly the
// two credit-bearing supertitles in the feed, and NO marketing line moved. The 19 that a bare-name rule
// would have taken are all still refused, which the case above asserts by name.
@Suite("The supertitle boundary, measured against the whole live feed (#2554)")
struct SuperTitleCalibrationTests {

    private func corpus() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/venuetix-supertitles/2026-08-13.json")
        let obj = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        return (obj?["superTitles"] as? [String]) ?? []
    }

    // Every phrase in the feed the rule calls a producer, read by eye before being written down. A change
    // that accepts a 31st puts it in front of somebody rather than sliding past: that is the whole job of
    // this test, because the failure this area actually has is silent over-matching.
    @Test func theAcceptedSetIsExactlyThis() throws {
        let sts = try corpus()
        #expect(sts.count == 148)
        let accepted = Set(sts.compactMap { ProducerShapedName.from($0) })

        let companies: Set<String> = [
            "Acting Up Entertainment", "Aurora Light Production", "Chorus Girl Productions",
            "Em&Em Productions", "ICB Productions", "Madison Ablin Productions", "Moore Productions",
            "New York Theatre Barn", "Niche Media Productions", "Performance Check Productions",
            "Peytons Productions", "Productions by Stephan", "Tel\u{00F3}n de Agave",
            "Underbelly Theatre Company", "Vivace Arts Collective", "What\u{2019}s Inside Productions",
        ]
        // People billing a show under their own name, which the possessive arm has always accepted: the
        // self-producing headliner ListingOrganiserTests already says is kept.
        let selfProducers: Set<String> = [
            "A SHARP", "Ilka Brannon and Peder Lasko", "Ilan Rooke", "Tobin Wray",
            "Marit Vale Osgood", "Harvard", "Jack and Friends", "Perrin Okada", "Robyn Estal",
            "Tamsin Reddick", "Lenka Fiore",
        ]
        // #2554's two, and the entire measured gain on this feed.
        let newlyCredited: Set<String> = ["Oc\u{00E9}ane Vireux", "Sullivan Roarke"]

        #expect(accepted == companies.union(selfProducers).union(newlyCredited))
        // 29 distinct NAMES out of 30 accepted supertitles: the feed bills "Productions by Stephan" both
        // with and without its possessive, and both fold to the one company, which is what
        // `withoutPossessive` is for. Both numbers are stated because they are different questions and
        // reading one as the other is how a count starts lying about the rows behind it (L16).
        #expect(accepted.count == 29)
        #expect(sts.filter { ProducerShapedName.from($0) != nil }.count == 30)
    }

    // Stated as its own assertion because it is the claim the whole change rests on: widening the credit
    // moved the boundary by exactly the credits, and touched nothing else in 148 real lines.
    @Test func wideningTheCreditAddedOnlyTheCredits() throws {
        let sts = try corpus()
        let accepted = Set(sts.compactMap { ProducerShapedName.from($0) })
        #expect(accepted.contains("Sullivan Roarke"))
        #expect(accepted.contains("Oc\u{00E9}ane Vireux"))
        // Everything else the rule accepts, it accepted before: 30 accepted supertitles less the two, and
        // 27 distinct names, which is what the 2026-08-07 calibration's boundary comes to on this feed.
        #expect(sts.filter { ProducerShapedName.from($0) != nil }.count - 2 == 28)
        #expect(accepted.count - 2 == 27)
    }
}
