import Testing
import Foundation
import SwiftData
@testable import Overture

// #1687: prove the card's presenter rule against a COPY of Dan's real store. The unit tests next door pin
// each of the four gates on hand-built rows; this one asks whether the rule, meeting 559 real shows, 547
// real presenter strings and 114 real venue spellings, draws the names he asked for and stays silent on
// the rooms. The whole reason #1687 is a rule and not a field is a claim about proportions, and a
// proportion can only be measured here.
//
// Gated on the live store existing, so a machine without one reports a visible SKIP rather than a silent
// pass. Reads a copy and writes nothing anywhere.
@Suite("The presenter line, live store (#1687)")
struct PresenterLineLiveStoreTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private func copyLiveStore(to dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Overture.store")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: Self.liveStoreURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
        }
        return dest
    }

    private func openContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      url: url, cloudKitDatabase: .none)])
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="untriaged rows whose presenter names a group the card never showed, and the rooms the rule must not name"
    // Measured 2026-07-29 on 559 rows at status = new: 547 carry a presenter, 272 differ from both the
    // title and the venue, 42 of those are the building's own brand, 15 more are already named in the
    // title, and 215 draw the line. Asserted as PROPORTIONS with headroom rather than exact counts,
    // because the store grows every night and a test that pins today's number would fail tomorrow for no
    // reason (#1687's counts are recorded in the issue and in QueueModel.presenterLine's comment).
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theRuleDrawsAName0nRoughlyAThirdOfTheQueueAndStaysSilentOnTheRest() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1687-live-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            let brands = ProducerGate.VenueBrands(
                shows: all.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })
            let untriaged = all.filter { $0.status == .new }
            #expect(untriaged.count > 100, "the live store still holds a real untriaged queue to measure")

            let drawn = untriaged.filter {
                QueueModel.presenterLine(title: $0.groupName, presenter: $0.presenter,
                                         venue: $0.venue, venueBrands: brands) != nil
            }
            // It must earn its place on a substantial minority of cards. Too few and the feature is not
            // worth a line; ALL of them would mean the gates stopped gating and the room names are back.
            #expect(drawn.count > untriaged.count / 5)
            #expect(drawn.count < untriaged.count * 3 / 4)

            // The brand gate is doing real work on THIS store, not just in a hand-built fixture. Without
            // it, houses draw as though they were the act; asserted so the gate can never go vacuous
            // while every unit test stays green.
            let withoutBrandGate = untriaged.filter {
                QueueModel.presenterLine(title: $0.groupName, presenter: $0.presenter,
                                         venue: $0.venue) != nil
            }
            #expect(withoutBrandGate.count > drawn.count)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="the named rows #1687 was filed about, and the named rooms it must never draw"
    // The specific shows from the issue, by name, because a proportion can hold while the exact cards Dan
    // complained about still read wrong. Carnegie Hall Presents is the house's own brand over rooms
    // spelled "Stern Auditorium"; Jalopy Theatre is the room; Young New Yorkers' Chorus is the ensemble he
    // could only see because he had booked them before.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theCardsTheIssueWasFiledAboutReadTheWayHeAsked() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1687-named-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            let brands = ProducerGate.VenueBrands(
                shows: all.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })

            func lines(presentedBy presenter: String) -> [String?] {
                let rows = all.filter { ProducerGate.key($0.presenter) == ProducerGate.key(presenter) }
                #expect(!rows.isEmpty, "the live store still holds shows presented by \(presenter)")
                return rows.map {
                    QueueModel.presenterLine(title: $0.groupName, presenter: $0.presenter,
                                             venue: $0.venue, venueBrands: brands)
                }
            }

            // The ask. Every YNYC row names the chorus, whether or not it carries a past-client pill.
            #expect(lines(presentedBy: "Young New Yorkers' Chorus")
                .allSatisfy { $0 == "Young New Yorkers' Chorus" })

            // The trap. Neither of these ever draws, on any of its rows.
            #expect(lines(presentedBy: "Carnegie Hall Presents").allSatisfy { $0 == nil })
            #expect(lines(presentedBy: "Jalopy Theatre").allSatisfy { $0 == nil })
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
