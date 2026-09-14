import Testing
import Foundation

// #3345. Was the check held to its own procedure.
//
// `docs/prep-runbook.md`'s waterfall step (b) requires a fetch of the target's canonical
// `firstnamelastname.com` before any answer about them is final. #2265 measured that step being skipped
// on 2026-08-07, and #3345 measured the consequence: 31 of the 37 shows the check wrote off as
// `named_but_no_route` later turned out to hold a route, usually on the person's OWN domain.
//
// The run records what it did. Every tool call it makes is written to its event stream, so whether it
// performed step (b) for a given person is a question about evidence the run itself produced, not a
// declaration it makes about itself (L27: a rule that lives only in a prompt is a hope, and so is a
// field the prompt is the only writer of).
//
// This is the READING. It refuses nothing and settles nothing: Dan's call, 2026-09-06, on being shown
// that the mechanism cannot currently be reproduced (see the archive suite beside this). Enforcing on an
// unmeasured signal is how a guard comes to fire on the ordinary case and get switched off within a day
// (L93, L506, L142).
@Suite("Was the canonical domain tried (#3345)")
struct CanonicalDomainProcedureTests {

    // MARK: the token

    @Test func aPersonsNameFoldsToTheDomainTheRunbookAsksFor() {
        #expect(CanonicalDomainProcedure.canonicalToken(forName: "Bethany Livers") == "bethanylivers")
        #expect(CanonicalDomainProcedure.canonicalToken(forName: "  Logan   Baxter ") == "loganbaxter")
        #expect(CanonicalDomainProcedure.canonicalToken(forName: "Aidan S. Wells") == "aidanswells")
    }

    // Accents fold, because the domain does not carry them and the name routinely does. Measured on the
    // live feed 2026-09-06, which bills a producer as `Oc\u{00E9}ane Vireux`.
    @Test func anAccentedNameFoldsTheWayADomainWould() {
        #expect(CanonicalDomainProcedure.canonicalToken(forName: "Oc\u{00E9}ane Vireux") == "oceanevireux")
    }

    // ONE word is not the runbook's case, and this is the guard against the rule reaching past what it
    // was written for. Step (b) is about a named PERSON's own site; a single word is a company, a stage
    // name or an act, and `sohoplayhouse` would match the venue's own domain on every show in the room.
    @Test func aSingleWordNameIsNotAPersonsCanonicalDomain() {
        #expect(CanonicalDomainProcedure.canonicalToken(forName: "Bargemusic") == nil)
        #expect(CanonicalDomainProcedure.canonicalToken(forName: "") == nil)
        #expect(CanonicalDomainProcedure.canonicalToken(forName: nil) == nil)
    }

    // MARK: reading the stream

    private func toolUse(_ name: String, _ input: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"\#(name)","input":\#(input)}]}}"#
    }

    @Test func theStreamYieldsTheHostsTheRunActuallyFETCHED() {
        let lines = [
            toolUse("WebFetch", #"{"url":"https://bethanylivers.com/contact"}"#),
            toolUse("WebFetch", #"{"url":"https://WWW.LoganBaxter.com/"}"#),
            toolUse("WebSearch", #"{"query":"aidan s wells music director"}"#),
            #"{"type":"system","subtype":"init","session_id":"abc"}"#,
            "not json at all",
        ]
        let hosts = CanonicalDomainProcedure.fetchedHosts(inStreamLines: lines)
        #expect(hosts == ["bethanylivers.com", "loganbaxter.com"])
    }

    // A SEARCH is not the step. #2265's whole finding is a run that found a doorway and did not open it,
    // so counting a search that merely names somebody as having tried their site would report the exact
    // failure this exists to see as compliance.
    @Test func aSearchNamingThePersonIsNotTheStep() {
        let lines = [toolUse("WebSearch", #"{"query":"bethany livers besoli productions"}"#)]
        #expect(CanonicalDomainProcedure.fetchedHosts(inStreamLines: lines).isEmpty)
    }

    // The guard is on the tool's NAME, not on the shape of its input, and this is what makes that real.
    // Measured over every event stream on this Mac, 2026-09-06: of the seven tools these runs use (Read,
    // ToolSearch, WebSearch, WebFetch, Bash, Write, Edit) only WebFetch carries a `url` at all, so this
    // fixture names a SHAPE rather than a tool in use. It is still wanted, because the run's tool scope
    // is a shell variable (`PREP_ALLOWED_TOOLS`) and the day a browser or a fetch MCP joins it, a
    // navigate would otherwise read as the run having opened their site.
    //
    // Found by mutation: deleting the name check left every test green, because both search fixtures
    // carry a `query` and no `url`, so the input shape was answering for the name (L1, L135).
    @Test func aToolThatIsNotAFetchDoesNotCountEvenWhenItCarriesAUrl() {
        let lines = [toolUse("Read", #"{"url":"https://bethanylivers.com/"}"#)]
        #expect(CanonicalDomainProcedure.fetchedHosts(inStreamLines: lines).isEmpty)
    }

    // A line this reader cannot parse is skipped, never counted as a fetch and never fatal: a stream is
    // written by another process while a run is live, so a half-written last line is ordinary.
    @Test func anUnparseableLineIsSkippedRatherThanCounted() {
        let lines = ["{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_",
                     toolUse("WebFetch", #"{"url":"https://bethanylivers.com/"}"#)]
        #expect(CanonicalDomainProcedure.fetchedHosts(inStreamLines: lines) == ["bethanylivers.com"])
    }

    // MARK: the question

    @Test func aFetchOfTheirOwnDomainCountsAsTheStep() {
        #expect(CanonicalDomainProcedure.judgement(name: "Bethany Livers",
                                                   fetchedHosts: ["bethanylivers.com"]) == .tried)
    }

    // A subdomain of their own site counts: the step is "go to their own site", and the live evidence
    // carries `baileyswilley.substack.com` beside `baileyswilley.com`.
    @Test func aSubdomainOfTheirOwnSiteCountsAsTheStep() {
        #expect(CanonicalDomainProcedure.judgement(name: "Baileys Willey",
                                                   fetchedHosts: ["baileyswilley.substack.com"]) == .tried)
    }

    // A hyphenated domain counts, and this is a real one: the 2026-08-30 run fetched
    // `rebeccastevens-walter.com` for a person billed as Rebecca Stevens Walter. Comparing the raw host
    // would have called that a skipped step, which is a false accusation about a run that complied.
    @Test func aHyphenatedDomainIsStillTheirOwnSite() {
        #expect(CanonicalDomainProcedure.judgement(name: "Rebecca Stevens Walter",
                                                   fetchedHosts: ["rebeccastevens-walter.com"]) == .tried)
    }

    @Test func somebodyElsesDomainIsNotTheStep() {
        #expect(CanonicalDomainProcedure.judgement(
            name: "Bethany Livers", fetchedHosts: ["baileyswilley.com", "instagram.com"]) == .notTried)
    }

    // A name this cannot fold is UNANSWERABLE, not a skipped step. A one-word act with no canonical
    // domain to try must never be counted as a run that failed to try one, or the reading would report
    // its own blind spot as a finding about the check (L11, L98).
    @Test func aNameWithNoCanonicalDomainIsNotJudged() {
        #expect(CanonicalDomainProcedure.judgement(name: "Bargemusic", fetchedHosts: ["anything.com"])
                == .noCanonicalDomainToTry)
        #expect(CanonicalDomainProcedure.judgement(name: "Bethany Livers", fetchedHosts: [])
                == .notTried)
        #expect(CanonicalDomainProcedure.judgement(name: "Bethany Livers",
                                                   fetchedHosts: ["bethanylivers.com"]) == .tried)
    }
}
