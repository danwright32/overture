import Testing
import Foundation

// #1598 Phase 5: the rules are unit tested (OrgAnswerLedgerTests), but a rule and its wiring are two
// separate claims, and the wiring lives inside SwiftUI views a running test cannot build. Everything
// below would sit green and dead if the ledger were simply never handed to the queue, which is the exact
// shape of failure this guard exists to catch.
@Suite("The queue is really wired to the organisation ledger (#1598)")
struct InheritedReachabilityWiringGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }
    private var archiveView: String { SourceGuardHelper.source("Overture/UI/ArchiveView.swift") }
    private var rowView: String { SourceGuardHelper.source("Overture/UI/ProspectRowView.swift") }
    private var settle: String { SourceGuardHelper.source("Overture/Integration/PrepQueueService.swift") }

    // The queue reads the ledger, and passes the WHOLE store as the gate's corpus rather than its own
    // dismissed-filtered query. Passing `prospects` here would silently let a dismiss change which
    // organisations qualify, and every unit test would still pass.
    @Test func theQueueFeedsTheLedgerAndTheWholeStore() {
        #expect(queueView.contains("@Query private var orgAnswers: [OrgReachabilityAnswer]"))
        #expect(queueView.contains("@Query private var allProspects: [Prospect]"))
        #expect(queueView.contains("QueueModel.items(from: prospects, answers: orgAnswers, corpus: allProspects)"))
    }

    @Test func archiveReadsTheLedgerToo() {
        #expect(archiveView.contains("@Query private var orgAnswers: [OrgReachabilityAnswer]"))
        #expect(archiveView.contains("QueueModel.items(from: prospects, answers: orgAnswers)"))
    }

    // The address line reads the shared rule rather than `item.contacts` directly, or an inherited row
    // would wear the badge with no address under it, which is the state Dan rejected.
    @Test func theRowPrintsTheSharedAddressRule() {
        #expect(rowView.contains("item.displayedContactEmails"))
        #expect(rowView.contains("ReachabilityCopy.inheritedEmailFoundHelp"))
    }

    // The ledger is written from the settlement path, after the ingest. Written before it, every answer
    // would record markProbed's pre-guard "no email found" floor.
    @Test func settlementRecordsTheAnswer() {
        #expect(settle.contains("OrgAnswerRecording.record(answeredKeys: answered"))
        guard let recordAt = settle.range(of: "OrgAnswerRecording.record"),
              let ingestAt = settle.range(of: "PrepImporter.consumeIfNew") else {
            Issue.record("expected both the ingest and the ledger write in settleReachabilityProbe")
            return
        }
        #expect(ingestAt.lowerBound < recordAt.lowerBound)
    }
}
