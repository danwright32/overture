import Testing
import Foundation
import SwiftData

// #2408. #2392 gave Dan a control to strike an address before the prep run. Nothing anywhere showed him
// what he had struck, and one of the two scopes is effectively invisible once he leaves the card.
//
// A strike on a show's OWN contact is at least legible by its absence on that card. A strike on an
// INHERITED address is recorded against the whole ORGANISATION (his call, 2026-08-09), so it removes that
// address from every show that organisation ever puts on. Weeks later such a show shows one address fewer
// than the check found, with nothing on screen saying why.
//
// THE UNDO EXISTED AND WAS UNREACHABLE. Typing the address back in on any of that organisation's shows
// reverses it (`ContactRefusal.allow` clears both scopes, and `addRecipientManually` calls it). That is a
// real undo and it is deliberate (#2155, Dan's no-undo rule for removal at review). But it only works if
// he still remembers the address, and an organisation-level strike removes the very text he would need to
// retype. So it was reachable in principle and unreachable in practice for exactly the case with the
// widest blast radius.
//
// THE ORGANISATION HAS TO BE NAMED READABLY. The stored `scopeId` is a folded `OrgKey`, not a name Dan
// would recognise, so this resolves it against the store's own presenters.
//
// "REMOVED" AND "ASKED NOT TO BE CONTACTED" ARE NOT THE SAME THING and this listing may never let them
// read as one. A strike is Dan's own reversible choice; an organisation refusal is the one decision in
// the app that cannot be taken back. The Sources sheet has already had exactly this defect.
@Suite("The addresses Dan has struck, and the way back (#2408)")
struct StruckAddressListingTests {

    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func row(_ handle: String, scope: String, id: String, at: Date? = nil) -> StruckAddressListing.Row {
        StruckAddressListing.Row(handleKey: handle, scopeRaw: scope, scopeId: id, refusedAt: at ?? day)
    }

    private let shows: [StruckAddressListing.Show] = [
        .init(naturalKey: "kestrel quartet|2027-10-03|rowan hall", groupName: "Kestrel Quartet",
              presenter: "Halyard Theatre Company"),
        .init(naturalKey: "rowan trio|2027-11-02|rowan hall", groupName: "Rowan Trio",
              presenter: "Halyard Theatre Company"),
    ]

    // An organisation strike names the ORGANISATION, in the spelling Dan would recognise, not the folded
    // key the row stores.
    @Test func anOrganisationStrikeNamesTheOrganisation() throws {
        let orgKey = try #require(OrgKey.stored(for: "Halyard Theatre Company"))
        let listing = StruckAddressListing.build(
            rows: [row("booking@halyard.example", scope: "organisation", id: orgKey)], shows: shows)

        let entry = try #require(listing.first)
        #expect(entry.handle == "booking@halyard.example")
        #expect(entry.scopeName == "Halyard Theatre Company")
        #expect(entry.appliesToEveryShowBy)
        #expect(entry.refusedAt == day)
    }

    // A show strike names the SHOW, and says so, because the two have very different blast radius and the
    // whole reason this surface exists is that one of them is invisible.
    @Test func aShowStrikeNamesTheShow() throws {
        let listing = StruckAddressListing.build(
            rows: [row("wrong@example.com", scope: "show", id: "kestrel quartet|2027-10-03|rowan hall")],
            shows: shows)

        let entry = try #require(listing.first)
        #expect(entry.scopeName == "Kestrel Quartet")
        #expect(!entry.appliesToEveryShowBy)
    }

    // An organisation whose shows have all left the store cannot be named, and the entry says so rather
    // than printing the folded key at him or being dropped. Dropping it would hide a strike that is still
    // in force, which is the exact defect this surface exists to fix (L98, L11).
    @Test func anOrganisationNoShowNamesAnyMoreStillAppears() throws {
        let listing = StruckAddressListing.build(
            rows: [row("booking@gone.example", scope: "organisation", id: "some folded key")], shows: shows)

        let entry = try #require(listing.first)
        #expect(entry.scopeName == StruckAddressCopy.unnamedOrganisation)
        #expect(entry.appliesToEveryShowBy)
    }

    // A scope this build does not know is kept and marked, never dropped, for the same reason.
    @Test func ascopeThisBuildDoesNotKnowIsStillShown() throws {
        let listing = StruckAddressListing.build(
            rows: [row("a@example.com", scope: "something-new", id: "x")], shows: shows)
        #expect(listing.count == 1)
        #expect(try #require(listing.first).scopeName == StruckAddressCopy.unnamedOrganisation)
    }

    // Newest first, because the one he is most likely to be looking for is the one he just made, and a
    // stable order after that so the list does not reshuffle under him between reads.
    @Test func theNewestStrikeIsFirst() {
        let older = day
        let newer = day.addingTimeInterval(86_400)
        let listing = StruckAddressListing.build(rows: [
            row("old@example.com", scope: "show", id: "kestrel quartet|2027-10-03|rowan hall", at: older),
            row("new@example.com", scope: "show", id: "kestrel quartet|2027-10-03|rowan hall", at: newer),
        ], shows: shows)
        #expect(listing.map(\.handle) == ["new@example.com", "old@example.com"])
    }

    // A FORM handle is struck the same way an address is (#2438), so it belongs on this list and has to
    // read as what it is rather than as a malformed address.
    @Test func aStruckFormReadsAsALinkRatherThanAnAddress() throws {
        let listing = StruckAddressListing.build(
            rows: [row("form:https://kestrelquartet.example/contact", scope: "show",
                       id: "kestrel quartet|2027-10-03|rowan hall")],
            shows: shows)
        let entry = try #require(listing.first)
        #expect(entry.handle == "https://kestrelquartet.example/contact")
        #expect(entry.isLink)
    }

    // Nothing struck is its own state, and it says what the list is FOR rather than that it is empty,
    // because an empty list with no sentence reads as a surface that is broken.
    @Test func nothingStruckSaysWhatTheListIsFor() {
        #expect(StruckAddressListing.build(rows: [], shows: shows).isEmpty)
        #expect(StruckAddressCopy.emptyState
                == "You haven't removed any addresses. Removing one on a card puts it here, so you can put it back.")
    }

    // MARK: - Wired, not merely built (L3)

    // A listing nothing opens is a list nobody reads, which is the state #2408 is about. Asserted
    // on the source, because the connection between a toolbar button and a sheet is the thing a
    // runtime test of the listing cannot see.
    @Test func thesheetIsReachableFromTheApp() {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!root.isEmpty)
        #expect(SourceGuardHelper.containsCode("StruckAddressesView()", in: root), Comment(rawValue:
            "the sheet is built and nothing presents it, so the list Dan needs cannot be opened"))
        #expect(SourceGuardHelper.containsCode("showStruckAddresses = true", in: root), Comment(rawValue:
            "nothing raises the sheet, so the state it is bound to can never become true"))
    }

    // Putting one back really clears BOTH scopes, driven against a store rather than asserted about the
    // source. The source guard below is kept and is not enough on its own: it can see that
    // `ContactRefusal.allow` is called and not what it is handed, and a mutation passing `orgKey: nil`
    // satisfies it perfectly while leaving the organisation strike standing behind a contact now back on
    // the card (L178). Measured: that exact mutation SURVIVED the source guard.
    @MainActor
    @Test func puttingOneBackClearsBothScopesNotOnlyTheOneItWasListedUnder() throws {
        let ctx = ModelContext(try ModelContainer(
            for: AppSchema.schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let orgKey = try #require(OrgKey.stored(for: "Halyard Theatre Company"))
        let showKey = "kestrel quartet|2027-10-03|rowan hall"
        let address = "booking@halyard.example"

        // Struck at BOTH scopes for one address, which is the state `allow` exists for and the state a
        // bare delete of one row would only half clear.
        ContactRefusal.refuse(email: address, scope: .show(showKey), in: ctx)
        ContactRefusal.refuse(email: address, scope: .organisation(orgKey), in: ctx)
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<RefusedContactAddress>()).count == 2)

        // Listed under the ORGANISATION, which is the entry Dan would press on this surface.
        let storedRows: [StruckAddressListing.Row] =
            try ctx.fetch(FetchDescriptor<RefusedContactAddress>()).map {
                .init(handleKey: $0.handleKey, scopeRaw: $0.scopeRaw, scopeId: $0.scopeId,
                      refusedAt: $0.refusedAt)
            }
        let entry = try #require(StruckAddressListing.build(
            rows: storedRows,
            shows: [.init(naturalKey: showKey, groupName: "Kestrel Quartet",
                          presenter: "Halyard Theatre Company")])
            .first { $0.appliesToEveryShowBy })

        StruckAddressMutations.putBack(entry, rows: storedRows, context: ctx,
                                       feedback: ActionFeedback())
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<RefusedContactAddress>()).isEmpty, Comment(rawValue:
            "one scope is still refusing the address, so it is back on some cards and not others"))
    }

    // Putting one back goes through `ContactRefusal.allow` and never a bare delete, which is what
    // #2408 asks for. A strike can be recorded at BOTH scopes for one address and `allow` clears the
    // pair, so deleting the row this listing happens to show would leave the other scope standing
    // behind a contact now back on the card (L16).
    @Test func puttingOneBackGoesThroughTheSharedUndo() {
        let source = SourceGuardHelper.source("Overture/UI/StruckAddressMutations.swift")
        #expect(!source.isEmpty)
        #expect(SourceGuardHelper.containsCode("ContactRefusal.allow(", in: source), Comment(rawValue:
            "the restore does not go through the shared undo, so a strike recorded at both scopes is "
            + "only half cleared"))
        #expect(!SourceGuardHelper.containsCode("context.delete(", in: source), Comment(rawValue:
            "the restore deletes a row itself, which clears one scope and leaves the other"))
    }

    // The two must never read as one thing. A strike is Dan's own reversible choice; an organisation
    // refusal is the one decision in the app that cannot be taken back, and the Sources sheet has already
    // had this exact defect.
    @Test func removedAndAskedNotToBeContactedAreDifferentSentences() {
        #expect(StruckAddressCopy.heading != SourceGrade.stoppedAtTheirRequest.explanation)
        #expect(!StruckAddressCopy.heading.lowercased().contains("asked not to be contacted"))
        #expect(StruckAddressCopy.explanation.contains("You removed"))
    }
}
