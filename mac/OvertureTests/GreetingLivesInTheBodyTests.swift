import Testing
import Foundation
import SwiftData

// #2545. Dan, 2026-08-11, on a Final review card showing an `Attn:` line, then `Hello,`, then a notice
// explaining that the body would say hello a second time: "I want to eliminate the appended greeting.
// It should just be included in the AI prep or manual prep where I write it myself. It's confusing to
// have it there twice."
//
// #2010 put the app's opening on screen so nothing was added invisibly at send. It did not remove the
// second place a greeting could come from, so the app could not tell which one he meant. There is now
// exactly ONE: the body, written by whoever writes the body.
//
// Dan's calls, 2026-08-12:
//   - a single contact is greeted by name, two or more get a plain "Hello," with no names
//   - the `Attn:` block for a shared inbox is written into the body too, not appended
//   - a body that does not greet is HELD at send, with an override he can take deliberately
//
// LIVE-STORE-CLAIM verified=2026-08-12 measure="shows carrying a written draft body, how many open with a greeting, and how many are queued to send"
// Measured before building: 14 shows carry a written draft body and 10 of them do not open with a
// greeting. None is in `drafted` status, and all 7 still-pending recipients behind those bodies sit on
// dismissed shows, so nothing is queued behind a headless body today. The exposure the hold covers is a
// draft written before this change and sent after it.
@MainActor
@Suite("The greeting lives in the body (#2545)")
struct GreetingLivesInTheBodyTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func prospect(_ ctx: ModelContext, body: String?) -> Prospect {
        let p = Prospect(naturalKey: "k|2026-09-12|weill", groupName: "Aurora Strings",
                         discipline: "music", venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.draftSubject = "Photographs of your concert"
        p.draftBody = body
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ ctx: ModelContext, on p: Prospect, id: String, name: String?,
                         method: ContactMethod = .namedDecisionMaker) -> Recipient {
        let r = Recipient(id: id, email: id, name: name, provenance: .presenter,
                          contactMethodRaw: method.rawValue)
        p.recipients.append(r)
        ctx.insert(r)
        return r
    }

    // MARK: nothing is composed above the body any more

    // The whole of the issue in one assertion: what leaves is what is in the box.
    @Test func theoutgoingPitchIsTheBodyAndNothingAboveIt() throws {
        let ctx = try context()
        let body = "Hi Emma,\n\nI photograph performing arts in New York and saw your September concert."
        let p = prospect(ctx, body: body)
        let r = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")

        #expect(OutgoingPitch.text(for: r, of: p) == body)
    }

    // The same for the joint send, which had its own opening composer (`JointOpening`) for the same
    // reason and so had the same defect.
    @Test func ajointPitchIsAlsoTheBodyAndNothingAboveIt() throws {
        let ctx = try context()
        let body = "Hello,\n\nI photograph performing arts in New York and saw your September concert."
        let p = prospect(ctx, body: body)
        let emma = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")
        let tom = contact(ctx, on: p, id: "tom@aurora.example", name: "Tom Reyes")

        #expect(OutgoingPitch.text(forGroup: [emma, tom], of: p) == body)
    }

    // A shared inbox used to get an `Attn:` block composed on top of the greeting. Both are the
    // drafter's job now, so the app still adds nothing even in the one case where it used to add most.
    @Test func asharedInboxPitchIsTheBodyToo() throws {
        let ctx = try context()
        let body = "Attn: Raphaele de Boisblanc, Interim Director of Marketing\n\nHello,\n\nI photograph performing arts in New York."
        let p = prospect(ctx, body: body)
        let r = contact(ctx, on: p, id: "info@mmdg.example", name: "Raphaele de Boisblanc",
                        method: .genericInbox)

        #expect(OutgoingPitch.text(for: r, of: p) == body)
    }

    // Carried over from #2010's suite, which #2545 replaces: these two assert behaviour that SURVIVES the
    // change, so deleting that file without them would have quietly dropped the coverage.

    // A group whose members would not read the same words has no single email to compose, so there is
    // nothing to return rather than a guess at whose letter wins.
    @Test func agroupWithDifferentLettersHasNoJointEmail() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "Hello,\n\nI photograph performing arts in New York.")
        let emma = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")
        let virgile = contact(ctx, on: p, id: "virgile@aurora.example", name: "Virgile Roche")
        virgile.provenance = .performer
        virgile.overrideBody = "Hi Virgile,\n\nI photograph performing arts in New York."

        #expect(OutgoingPitch.text(forGroup: [emma, virgile], of: p) == nil)
    }

    // The copy path and the send path must never differ, which is what OutgoingPitch exists for. A
    // performer's own second-person draft still wins over the shared body.
    @Test func aperformersOwnDraftStillWinsOverTheSharedBody() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "Hello,\n\nI photograph performing arts in New York.")
        let virgile = contact(ctx, on: p, id: "virgile@aurora.example", name: "Virgile Roche")
        virgile.provenance = .performer
        virgile.overrideBody = "Hi Virgile,\n\nYour recital caught my eye."

        #expect(OutgoingPitch.text(for: virgile, of: p) == "Hi Virgile,\n\nYour recital caught my eye.")
    }

    // MARK: what counts as opening with a greeting

    @Test(arguments: [
        "Hi Emma,\n\nI photograph performing arts.",
        "Hello,\n\nI photograph performing arts.",
        "Dear Ms Chen,\n\nI photograph performing arts.",
        "Hey Emma,\n\nI photograph performing arts.",
        "Attn: Raphaele de Boisblanc, Marketing\n\nHello,\n\nI photograph performing arts.",
    ])
    func abodyThatGreetsIsRecognised(_ body: String) {
        #expect(DraftGreeting.opensWithAGreeting(body), "should count as greeting: \(body)")
    }

    // Dan's OWN greetings, which are the ones that matter most here: the drafter follows the runbook and
    // opens "Hi <name>," or "Hello,", but he types what reads naturally to him, and a greeting that leads
    // with the person's name is completely ordinary. The first version of this rule only recognised an
    // opener WORD at the start, so "Marcus, hello again," was refused and he would have met the override
    // every time he wrote in his own voice, which is how a deliberate two-step gate stops meaning anything.
    //
    // His call, 2026-08-12: a short opening line ending in a comma is a greeting, whatever it starts with.
    @Test(arguments: [
        "Marcus, hello again,\n\nI photograph performing arts.",
        "Emma, good to hear from you,\n\nI photograph performing arts.",
        "Morning Emma,\n\nI photograph performing arts.",
        "Sarah and Tom,\n\nI photograph performing arts.",
    ])
    func agreetingInDansOwnVoiceIsAccepted(_ body: String) {
        #expect(DraftGreeting.opensWithAGreeting(body), "should count as greeting: \(body)")
    }

    // The line has to look like a GREETING, not merely end in a comma. A real first sentence that happens
    // to carry an early comma must still read as headless, or the hold accepts every draft and protects
    // nothing.
    @Test(arguments: [
        "I photograph performing arts in New York, and I saw your September concert.",
        "Aurora Strings are playing Carnegie Hall in March, which is why I am writing.",
    ])
    func afirstSentenceWithACommaIsStillNotAGreeting(_ body: String) {
        #expect(!DraftGreeting.opensWithAGreeting(body), "should NOT count as greeting: \(body)")
    }

    @Test(arguments: [
        "I photograph performing arts in New York and saw your September concert.",
        "My name is Dan Wright and I photograph performing arts.",
        "Highlights from the season are attached.",
        "Attn: Raphaele de Boisblanc, Marketing\n\nI photograph performing arts in New York.",
    ])
    func abodyThatDoesNotGreetIsRecognised(_ body: String) {
        #expect(!DraftGreeting.opensWithAGreeting(body), "should NOT count as greeting: \(body)")
    }

    // The distinction Dan's rule turns on: does the greeting name a particular person? A filler is not
    // a name, so "Hi all," is a perfectly good way to open an email to several people.
    @Test(arguments: ["Hi Emma,\n\nrest", "Dear Ms Chen,\n\nrest", "Hey Tom,\n\nrest"])
    func agreetingThatNamesSomebodyIsRecognised(_ body: String) {
        #expect(DraftGreeting.namesSomeone(body), "should read as named: \(body)")
    }

    @Test(arguments: ["Hello,\n\nrest", "Hi all,\n\nrest", "Hi there,\n\nrest", "Hi everyone,\n\nrest",
                      "I photograph performing arts."])
    func agreetingThatNamesNobodyIsRecognised(_ body: String) {
        #expect(!DraftGreeting.namesSomeone(body), "should NOT read as named: \(body)")
    }

    // The two halves of the rule have to agree about what a greeting IS, or the protection has a hole
    // exactly where Dan's own writing is. Once "Marcus, hello again," counted as a greeting but not as a
    // NAMED one, a show with two contacts would have sent it unheld: the greeting check saw a greeting,
    // the naming check saw nothing it recognised, and the person it addresses is one of two readers.
    @Test(arguments: ["Marcus, hello again,\n\nrest", "Morning Emma,\n\nrest", "Sarah and Tom,\n\nrest",
                      "Emma, good to hear from you,\n\nrest"])
    func agreetingInDansOwnVoiceStillCountsAsNamingSomebody(_ body: String) {
        #expect(DraftGreeting.namesSomeone(body), "should read as named: \(body)")
    }

    // And the impersonal ones he might write stay impersonal, or every multi-contact show is held on a
    // greeting that names nobody.
    @Test(arguments: ["Good to hear from you,\n\nrest", "Thanks for the quick reply,\n\nrest",
                      "Hello again,\n\nrest"])
    func animpersonalGreetingInDansOwnVoiceNamesNobody(_ body: String) {
        #expect(!DraftGreeting.namesSomeone(body), "should NOT read as named: \(body)")
    }

    // MARK: the send hold on a body that does not greet

    // Every draft in the store was written under the old rule, so its body has no greeting. Sending one
    // now would put out a headless email, which is worse than saying hello twice.
    @Test func abodyThatDoesNotGreetIsNotSendable() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "I photograph performing arts in New York and saw your concert.")
        p.status = .approved
        let r = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")

        #expect(r.draftIsMissingGreeting)
        #expect(!r.isSendablePending, "a headless body must not go out")
    }

    @Test func abodyThatGreetsIsSendable() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "Hi Emma,\n\nI photograph performing arts in New York.")
        p.status = .approved
        let r = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")

        #expect(!r.draftIsMissingGreeting)
        #expect(r.isSendablePending)
    }

    // Dan's call: he can take the hold off deliberately. Pinned to the exact text, the same shape as the
    // draft lint's override, so editing the body afterwards re-arms it rather than carrying an approval
    // forward onto words nobody looked at.
    @Test func theoverrideClearsTheHoldForThatExactBodyOnly() throws {
        let ctx = try context()
        let headless = "I photograph performing arts in New York and saw your concert."
        let p = prospect(ctx, body: headless)
        p.status = .approved
        let r = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")

        r.greetingOverriddenBody = headless
        #expect(r.isSendablePending, "an override he took on this exact text lets it go")

        p.draftBody = headless + " Rehearsals start Monday."
        #expect(!r.isSendablePending, "editing the body re-arms the hold")
    }

    // MARK: the hold on a greeting that names one person but reaches several

    // The greeting is frozen into the body at draft time now, so it can no longer re-address itself when
    // the contact list changes. A reachability check that fills in a second address later is exactly how
    // "Hi Emma," ends up in front of Emma AND Tom, with nothing detecting it.
    @Test func anamedGreetingIsHeldOnceTheEmailReachesMoreThanOnePerson() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "Hi Emma,\n\nI photograph performing arts in New York.")
        p.status = .approved
        let emma = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")

        #expect(emma.isSendablePending, "one contact, greeted by name: correct")

        contact(ctx, on: p, id: "tom@aurora.example", name: "Tom Reyes")
        #expect(emma.greetingMisaddressed)
        #expect(!emma.isSendablePending, "a second contact makes the name wrong for the email they share")
    }

    @Test func aplainGreetingIsFineForSeveralPeople() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "Hello,\n\nI photograph performing arts in New York.")
        p.status = .approved
        let emma = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")
        contact(ctx, on: p, id: "tom@aurora.example", name: "Tom Reyes")

        #expect(!emma.greetingMisaddressed)
        #expect(emma.isSendablePending)
    }

    // Sending separately means one email per person, so a name in it is right however many contacts the
    // show carries.
    @Test func anamedGreetingIsFineWhenTheShowSendsSeparately() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "Hi Emma,\n\nI photograph performing arts in New York.")
        p.status = .approved
        p.sendsTogetherOverride = false
        let emma = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")
        contact(ctx, on: p, id: "tom@aurora.example", name: "Tom Reyes")

        #expect(!emma.greetingMisaddressed)
    }

    // A performer's own second-person letter (#634) goes to them alone, so it names them whatever else
    // is on the show.
    @Test func aperformersOwnLetterMayNameThemOnAMultiContactShow() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "Hello,\n\nI photograph performing arts in New York.")
        p.status = .approved
        let virgile = contact(ctx, on: p, id: "virgile@example.com", name: "Virgile Roche")
        virgile.provenance = .performer
        virgile.overrideBody = "Hi Virgile,\n\nI photograph performing arts in New York."
        contact(ctx, on: p, id: "info@presenter.example", name: nil, method: .genericInbox)

        #expect(!virgile.greetingMisaddressed)
    }

    // MARK: the hold is a WAIT, not a finish

    // #792's distinction, which this hold has to land on the right side of. `isSendablePending` is false
    // both for a contact that is FINISHED and for one that is WAITING, and SendService reads it to decide
    // a show is contacted. Land a live hold on the finished side and the show leaves the queue reading as
    // fully sent while a real person never received anything.
    @Test func agreetingHeldContactIsCountedAsWaitingOnDanNotAsDone() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "I photograph performing arts in New York and saw your concert.")
        p.status = .approved
        let r = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")

        #expect(!r.isSendablePending)
        #expect(r.isBlockedAwaitingReview, "a greeting hold waits on one glance from Dan, it is not done")
    }

    // MARK: what the card reports about the hold

    // The card's `greetingOverridden` decides whether the sentence tones down to "Sending despite..."
    // AND whether the Override button is still offered. So it must mean "nothing is held any more", not
    // "somebody has an override": with one overridden contact beside one that is still held, reading it
    // the second way tones the warning down and removes the way out while the send is genuinely still
    // blocked, which is the dead-end shape #2052 and #2012 were both filed for.
    //
    // Reachable in ordinary use: Dan overrides, and a later reachability check adds a second address.
    @Test func acardStillReportsTheHoldWhileAnyContactIsStillHeld() throws {
        let ctx = try context()
        let headless = "I photograph performing arts in New York and saw your concert."
        let p = prospect(ctx, body: headless)
        p.status = .approved
        let emma = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")
        emma.greetingOverriddenBody = headless
        contact(ctx, on: p, id: "tom@aurora.example", name: "Tom Reyes")   // arrived later, not overridden

        let item = QueueItem(p)

        #expect(item.draftMissingGreeting, "the finding is still there")
        #expect(!item.greetingOverridden, "one contact is still held, so the warning must not tone down")
    }

    @Test func acardReportsTheOverrideOnceNobodyIsHeld() throws {
        let ctx = try context()
        let headless = "I photograph performing arts in New York and saw your concert."
        let p = prospect(ctx, body: headless)
        p.status = .approved
        let emma = contact(ctx, on: p, id: "emma@aurora.example", name: "Emma Chen")
        emma.greetingOverriddenBody = headless

        let item = QueueItem(p)

        #expect(item.draftMissingGreeting, "the finding stays visible, that is the audit trail")
        #expect(item.greetingOverridden)
    }

    // MARK: the opener strip that keeps the AI from repeating itself

    // `RecentOpeners` compares how recent pitches started, so it has to look past the greeting. Now that
    // every body begins with one, and a shared-inbox body begins with an `Attn:` block above it, the
    // strip has to clear both or every opener it compares starts with the same two lines.
    @Test func theopenerStripRemovesTheAttnBlockAsWellAsTheGreeting() {
        let stripped = DraftGreeting.withoutLeadingOpening(
            "Attn: Raphaele de Boisblanc, Marketing\n\nHello,\n\nI photograph performing arts in New York.")

        #expect(stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                == "I photograph performing arts in New York.")
    }

    @Test func theopenerStripLeavesABodyWithNoOpeningAlone() {
        let body = "I photograph performing arts in New York."
        #expect(DraftGreeting.withoutLeadingOpening(body) == body)
    }
}
