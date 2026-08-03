import Testing

// #11: a deterministic self-check over a drafted email, surfaced before it reaches Dan's
// approval, so review is judgment not cleanup. Catches AI-tells / performative enthusiasm,
// em dashes, and the two stance failures from a real drafting session: presuming the
// booking, or hedging like a cold pitch at a warm/repeat client.
@Suite("Draft self-check")
struct DraftCheckTests {
    @Test func passesTheVersionDanActuallySent() {
        let good = """
        Hi Emma,

        I'm looking forward to being there again this year. If you'd like me to photograph \
        this year's event as well, just say the word.

        Best,
        Dan
        """
        #expect(DraftCheck.findings(in: good).isEmpty)
    }

    @Test func flagsPerformativeEnthusiasmAndExclamations() {
        #expect(DraftCheck.findings(in: "I'd love to photograph this.").contains { $0 == .performativeEnthusiasm })
        #expect(DraftCheck.findings(in: "I'm thrilled and can't wait.").contains { $0 == .performativeEnthusiasm })
        #expect(DraftCheck.findings(in: "Looking forward to it!").contains { $0 == .performativeEnthusiasm })
    }

    // #1141: an exclamation point that is part of the show's OWN title is the show's name, not enthusiasm
    // the drafter added, so it must not trip the performative-enthusiasm check.
    @Test func doesNotFlagAnExclamationThatBelongsToTheShowTitle() {
        let title = "Oh Em Gee, They Sang This on Glee!"
        let body = "Hi Sam, I photograph performances and would like to cover \(title) at 54 Below."
        #expect(!DraftCheck.findings(in: body, title: title).contains { $0 == .performativeEnthusiasm })
    }

    // But a stray exclamation the drafter added ELSEWHERE, on top of a title that ends in one, is still
    // caught: stripping the title must not blanket-clear every exclamation in the body.
    @Test func stillFlagsAnExclamationTheDrafterAddedOutsideTheTitle() {
        let title = "Oh Em Gee, They Sang This on Glee!"
        let body = "Hi Sam, I would love to cover \(title). It will be amazing!"
        #expect(DraftCheck.findings(in: body, title: title).contains { $0 == .performativeEnthusiasm })
    }

    // A performative WORD is independent of the title-exclamation exclusion: a title ending in "!" does
    // not license "thrilled" in the body.
    @Test func aTitleExclamationDoesNotExcusePerformativeWords() {
        let title = "Bang!"
        #expect(DraftCheck.findings(in: "I'm thrilled to cover \(title).", title: title)
            .contains { $0 == .performativeEnthusiasm })
    }

    // With no title supplied (the blocking-path and legacy call sites), behaviour is unchanged: any
    // exclamation flags.
    @Test func withNoTitleAnyExclamationStillFlags() {
        #expect(DraftCheck.findings(in: "Come see the show!").contains { $0 == .performativeEnthusiasm })
    }

    @Test func flagsEmDashes() {
        #expect(DraftCheck.findings(in: "I shoot performances — and I'm local.").contains { $0 == .emDash })
    }

    @Test func flagsPresumingTheBooking() {
        #expect(DraftCheck.findings(in: "Happy to lock in the photography plans for the concert.").contains { $0 == .presumesBooking })
        #expect(DraftCheck.findings(in: "I'll plan to cover the performance.").contains { $0 == .presumesBooking })
    }

    @Test func flagsColdHedgeAtAWarmClient() {
        #expect(DraftCheck.findings(in: "If you haven't arranged a photographer yet, I'm available.").contains { $0 == .coldHedge })
    }

    // #456: a draft must never ask the contact for a fact Overture already holds (the date or
    // venue). The deterministic guard fires ONLY when that fact is known; asking is legitimate
    // when Overture doesn't have it.
    @Test func flagsAskingForADateOvertureAlreadyKnows() {
        // The real #438 case that slipped through prompt-only enforcement.
        #expect(DraftCheck.findings(in: "Sounds great. Let me know the date and I'll be there.",
                                    knownsDate: true).contains { $0 == .asksForKnownFact })
        #expect(DraftCheck.findings(in: "When is the show?", knownsDate: true).contains { $0 == .asksForKnownFact })
        #expect(DraftCheck.findings(in: "What day works for you to have me there?", knownsDate: true).contains { $0 == .asksForKnownFact })
    }

    @Test func flagsAskingForAVenueOvertureAlreadyKnows() {
        #expect(DraftCheck.findings(in: "Happy to come. What venue is it at?", knownsVenue: true).contains { $0 == .asksForKnownFact })
        #expect(DraftCheck.findings(in: "Where is the performance being held?", knownsVenue: true).contains { $0 == .asksForKnownFact })
    }

    @Test func doesNotFlagAskingForAFactOvertureDoesNotHave() {
        // No date on file: asking the contact for it is the right thing to do.
        #expect(!DraftCheck.findings(in: "Let me know the date and I'll be there.", knownsDate: false).contains { $0 == .asksForKnownFact })
        #expect(!DraftCheck.findings(in: "What venue is it at?", knownsVenue: false).contains { $0 == .asksForKnownFact })
    }

    @Test func doesNotFlagADraftThatStatesTheKnownFact() {
        // Referencing the date/venue Overture knows is exactly what we want; only ASKING is wrong.
        let good = "I'll be at the Cathedral of St. John the Divine on April 12 to photograph the concert."
        #expect(!DraftCheck.findings(in: good, knownsDate: true, knownsVenue: true).contains { $0 == .asksForKnownFact })
    }

    @Test func knownFactCheckIsOffByDefault() {
        // The legacy single-argument call site keeps its exact behavior: no known-fact context,
        // so the new flag never fires for callers that don't opt in.
        #expect(!DraftCheck.findings(in: "Let me know the date.").contains { $0 == .asksForKnownFact })
    }

    // #458: the #39 / Phase C concession rule, ported from prose in the runbook into code. A cold
    // pitch must never offer a discount or free/complimentary work, and the rate must stay the
    // canonical $250/hr + tax. Instruction-only enforcement is exactly what failed in #438/#456.
    @Test func flagsConcessionLanguage() {
        #expect(DraftCheck.findings(in: "I can offer a discount for this one.").contains { $0 == .concessionLanguage })
        #expect(DraftCheck.findings(in: "Happy to do it for free.").contains { $0 == .concessionLanguage })
        #expect(DraftCheck.findings(in: "I can throw in a complimentary print.").contains { $0 == .concessionLanguage })
        #expect(DraftCheck.findings(in: "My pricing is flexible.").contains { $0 == .concessionLanguage })
    }

    @Test func doesNotFlagFeelFreeAsConcession() {
        // "feel free" is natural warm phrasing, not an offer of free work.
        #expect(!DraftCheck.findings(in: "Feel free to reach out with any questions.").contains { $0 == .concessionLanguage })
    }

    @Test func flagsANonCanonicalRate() {
        #expect(DraftCheck.findings(in: "My rate is $200 an hour.").contains { $0 == .nonCanonicalRate })
        #expect(DraftCheck.findings(in: "It would be $1,500 for the evening.").contains { $0 == .nonCanonicalRate })
    }

    @Test func doesNotFlagTheCanonicalRate() {
        let good = "My rate is $250 an hour plus tax, with a one-hour minimum."
        #expect(!DraftCheck.findings(in: good).contains { $0 == .nonCanonicalRate })
        #expect(!DraftCheck.findings(in: good).contains { $0 == .concessionLanguage })
    }
}

// #789: the two findings that BLOCK the send rather than merely warning. Both are facts about the
// text that a stranger will read, and both are unambiguous enough that a false block is close to
// impossible: a link to a site that isn't Dan's (a 404, or worse, someone else's site, in a cold
// pitch), and an unfilled template slot the drafter left behind. Everything else DraftCheck knows,
// INCLUDING the non-canonical rate, stays advisory (Dan's call: the rate check fires on any dollar
// figure, so a draft mentioning a ticket price would have been blocked though it read perfectly).
@Suite("Draft lint: blocking findings")
struct DraftLintBlockingTests {
    @Test func onlyTheLinkAndPlaceholderFindingsBlock() {
        #expect(DraftIssue.foreignLink.isBlocking)
        #expect(DraftIssue.placeholder.isBlocking)
        #expect(DraftIssue.galleryPathLink.isBlocking)   // #1832
        #expect(!DraftIssue.nonCanonicalRate.isBlocking)
        #expect(!DraftIssue.emDash.isBlocking)
        #expect(!DraftIssue.performativeEnthusiasm.isBlocking)
        #expect(!DraftIssue.concessionLanguage.isBlocking)
        #expect(!DraftIssue.presumesBooking.isBlocking)
        #expect(!DraftIssue.coldHedge.isBlocking)
        #expect(!DraftIssue.asksForKnownFact.isBlocking)
    }

    // A body that trips only an advisory finding must stay SENDABLE: blockingFindings is the
    // send gate, and widening it to every finding would stop Dan on an em dash.
    @Test func blockingFindingsIgnoresAdvisoryOnes() {
        let advisoryOnly = "My rate is $500 an hour, and I'd love to be there."
        #expect(!DraftCheck.findings(in: advisoryOnly).isEmpty)
        #expect(DraftCheck.blockingFindings(in: advisoryOnly).isEmpty)
    }

    @Test func blocksALinkToAHostThatIsNotDans() {
        #expect(DraftCheck.blockingFindings(in: "Tickets at https://www.carnegiehall.org/tickets.") == [.foreignLink])
        #expect(DraftCheck.blockingFindings(in: "See my gallery at pixieset.com/aurora.") == [.foreignLink])
        #expect(DraftCheck.blockingFindings(in: "More at www.example.org.") == [.foreignLink])
    }

    // #1832: one link in every draft, the site itself, and the recipient clicks into whatever they
    // want to see. Dan's call 2026-07-30: "just always go to the same site and let them click into the
    // portfolio they want to see."
    @Test func allowsThePortfolioLinkItself() {
        #expect(DraftCheck.blockingFindings(in: "Recent work: danwrightphotography.com").isEmpty)
        #expect(DraftCheck.blockingFindings(in: "Recent work: https://danwrightphotography.com").isEmpty)
        #expect(DraftCheck.blockingFindings(in: "Recent work: https://www.danwrightphotography.com.").isEmpty)
    }

    // #1832: a deep link into one gallery is a choice on the recipient's behalf that Dan does not want
    // made. It is a blocker rather than an advisory because, unlike the rate or concession matchers, it
    // is an exact path comparison with nowhere for a false positive to come from, and it stays
    // overridable like every other block.
    @Test func blocksADeepLinkIntoOneGallery() {
        #expect(DraftCheck.blockingFindings(in: "Recent work: danwrightphotography.com/music") == [.galleryPathLink])
        #expect(DraftCheck.blockingFindings(in: "Recent work at https://danwrightphotography.com/dance.")
                == [.galleryPathLink])
        #expect(DraftCheck.blockingFindings(in: "See https://www.danwrightphotography.com/performing-arts")
                == [.galleryPathLink])
        #expect(DraftCheck.blockingFindings(in: "Bands: danwrightphotography.com/bands") == [.galleryPathLink])
        #expect(DraftCheck.blockingFindings(in: "Comedy: danwrightphotography.com/comedy") == [.galleryPathLink])
    }

    // A path Dan links deliberately that is not one of the five galleries is his own business: the rule
    // is "don't pick a gallery for them", not "never link a page".
    @Test func doesNotBlockANonGalleryPathOnHisOwnSite() {
        #expect(DraftCheck.blockingFindings(in: "About me: danwrightphotography.com/about").isEmpty)
        #expect(DraftCheck.blockingFindings(in: "danwrightphotography.com/contact").isEmpty)
        // A longer path that merely STARTS with a gallery name is a different page, not one of the five.
        #expect(DraftCheck.blockingFindings(in: "danwrightphotography.com/music-notes").isEmpty)
        #expect(DraftCheck.blockingFindings(in: "danwrightphotography.com/dancers").isEmpty)
    }

    // An address at his own domain is not a gallery link, and stripping emails before the scan is what
    // keeps a signature from tripping the block.
    @Test func doesNotReadAnEmailAsAGalleryLink() {
        #expect(DraftCheck.blockingFindings(in: "Reach me at music@danwrightphotography.com.").isEmpty)
    }

    // The matcher must not read ordinary prose as a link. A missing space after a period is the
    // dangerous one ("arts.The"), since it looks exactly like host.tld.
    @Test func doesNotReadOrdinaryProseAsALink() {
        #expect(DraftCheck.blockingFindings(in: "I photograph the performing arts.The show is in May.").isEmpty)
        #expect(DraftCheck.blockingFindings(in: "Documentary coverage, e.g. no flash, no staging.").isEmpty)
        #expect(DraftCheck.blockingFindings(in: "I shoot music.Comedy is new for me.").isEmpty)
    }

    // An email address is not a link: it can't 404, and Dan's own address appears in a signature.
    // A foreign address (a contact he was told to write to) must not block the send either.
    @Test func doesNotTreatAnEmailAddressAsALink() {
        #expect(DraftCheck.blockingFindings(in: "Reach me at dan@danwrightphotography.com.").isEmpty)
        #expect(DraftCheck.blockingFindings(in: "Copy tickets@carnegiehall.org if that's easier.").isEmpty)
    }

    @Test func blocksALeftoverBracketedPlaceholder() {
        #expect(DraftCheck.blockingFindings(in: "I saw [GROUP] is performing at [VENUE].") == [.placeholder])
        #expect(DraftCheck.blockingFindings(in: "Hi [NAME], I photograph performances.") == [.placeholder])
    }

    @Test func doesNotFlagOrdinaryPunctuationAsAPlaceholder() {
        #expect(DraftCheck.blockingFindings(in: "I photograph performances (quietly, no flash).").isEmpty)
        #expect(DraftCheck.blockingFindings(in: "The rate is $250 an hour plus tax.").isEmpty)
    }

    @Test func reportsBothBlockersWhenBothArePresent() {
        let bad = "Hi [NAME], see my work at https://smugmug.com/dan."
        let found = DraftCheck.blockingFindings(in: bad)
        #expect(found.contains(.placeholder))
        #expect(found.contains(.foreignLink))
    }
}
