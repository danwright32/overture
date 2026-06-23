import Testing
@testable import Overture

@Suite("Natural key canonicalization")
struct NaturalKeyTests {
    @Test func decodesHtmlEntitiesSoScrapedAndCleanNamesAgree() {
        // Scout output may carry raw entities (issue #25); a later run that fetched
        // the org's real site sees the decoded form. Both must produce one key.
        let scraped = Prospect.makeNaturalKey(
            groupName: "Susan &amp; the Choir", performanceDate: "2026-07-01", venue: "Weill Recital Hall")
        let clean = Prospect.makeNaturalKey(
            groupName: "Susan & the Choir", performanceDate: "2026-07-01", venue: "Weill Recital Hall")
        #expect(scraped == clean)
    }

    @Test func decodesNumericEntities() {
        let a = Prospect.makeNaturalKey(groupName: "Caf&#233; Quartet", performanceDate: "2026-07-01", venue: nil)
        let b = Prospect.makeNaturalKey(groupName: "Café Quartet", performanceDate: "2026-07-01", venue: nil)
        #expect(a == b)
    }

    @Test func normalizesUnicodeComposition() {
        // "é" as one codepoint vs "e" + combining accent must canonicalize identically.
        let composed = Prospect.makeNaturalKey(groupName: "Pli\u{00E9} Dance", performanceDate: "2026-07-01", venue: nil)
        let decomposed = Prospect.makeNaturalKey(groupName: "Plie\u{0301} Dance", performanceDate: "2026-07-01", venue: nil)
        #expect(composed == decomposed)
    }

    @Test func collapsesNonBreakingAndEnDashWhitespaceConsistently() {
        let nbsp = Prospect.makeNaturalKey(groupName: "The\u{00A0}Choir", performanceDate: "2026-07-01", venue: nil)
        let plain = Prospect.makeNaturalKey(groupName: "The Choir", performanceDate: "2026-07-01", venue: nil)
        #expect(nbsp == plain)
    }

    @Test func stillLowercasesAndJoins() {
        let k = Prospect.makeNaturalKey(groupName: "DCINY", performanceDate: "2026-07-01", venue: "Stern")
        #expect(k == "dciny|2026-07-01|stern")
    }
}
