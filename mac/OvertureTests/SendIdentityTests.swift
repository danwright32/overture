import Testing
import Foundation
@testable import Overture

// #360: the branded send confirmation shows a "From" line. That From must be the exact identity
// the email actually sends as, or the confirmation would reassure Dan with a lie. SendIdentity is
// the single source both the live sender and the confirmation read, so the two can never drift.
@Suite("Send identity")
struct SendIdentityTests {
    @Test func danWrightIdentityIsTheKnownSendingAddress() {
        #expect(SendIdentity.danWright.name == "Dan Wright")
        #expect(SendIdentity.danWright.email == "dan@danwrightphotography.com")
    }

    @Test func displayCombinesNameAndEmail() {
        #expect(SendIdentity.danWright.display == "Dan Wright <dan@danwrightphotography.com>")
    }

    // Drift guard: the raw sending address must live only in SendIdentity, never re-typed at a
    // send site or in the confirmation, so "what Dan is shown" and "what actually sends" are the
    // same constant. If either file hard-codes the address again, this fails.
    @Test func theSendingAddressIsNotHardCodedOutsideSendIdentity() {
        let address = "dan@danwrightphotography.com"
        #expect(!SourceGuardHelper.source("Overture/UI/ProspectMutations.swift").contains(address),
                "ProspectMutations must build the live sender from SendIdentity, not a re-typed address literal (#360).")
        #expect(!SourceGuardHelper.source("Overture/Domain/SendConfirmation.swift").contains(address),
                "SendConfirmation must read its From from SendIdentity, not a re-typed address literal (#360).")
        // #949: the reply/bounce checker identifies Dan's own address to tell his sends apart from a
        // stranger's reply. That "self" address is the same sending identity, so it reads SendIdentity
        // too rather than keeping its own copy that could silently drift from what actually sends.
        #expect(!SourceGuardHelper.source("Overture/Integration/GmailReplyChecker.swift").contains(address),
                "GmailReplyChecker must default its selfEmail from SendIdentity, not a re-typed address literal (#949).")
    }
}
