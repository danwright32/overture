import Testing
import Foundation
import SwiftData

// #2438: `RefusedContactAddress.emailKey` is renamed to `handleKey`, so a refusal can name a contact
// whose only handle is a form rather than only one with an address.
//
// The rename carries an `@Attribute(originalName:)`, which is the supported way to keep the column's
// data. This rehearses that against a COPY of Dan's real store rather than trusting it, because the rows
// it would lose are refusals he made by hand and would have to notice were gone before he could remake
// them. Nothing here writes to the live store: `LiveStoreClone` takes a consistent copy through SQLite's
// own backup, and everything below opens that.
//
// The rename needs no VALUE migration, which is the thing that makes it low risk and is asserted here
// rather than merely argued: `Recipient.makeId` canonicalizes an address through the very same
// `ReplyDetection.email` this column already stored, so every row already holds a valid handle.
@Suite("The refusal column survives being renamed to a handle (#2438)")
struct RefusedHandleMigrationLiveStoreTests {

    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    // Gated so a machine without a live store reports a visible SKIP rather than a silent pass.
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    // LIVE-STORE-CLAIM verified=2026-08-10 measure="refusals Dan has made by hand, read back after the column rename"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func everyRefusalDanMadeIsStillThereAfterTheRename() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory
                .appendingPathComponent("refusal-rename-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                await RealStoreTestLock.shared.release()
                return
            }

            // Opened under the CURRENT schema, which is the rename, exactly as Dan's own store is opened
            // at his next launch.
            let schema = Schema([Prospect.self, Recipient.self, RefusedContactAddress.self])
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: clone, cloudKitDatabase: .none)])
            let context = ModelContext(container)

            let rows = try context.fetch(FetchDescriptor<RefusedContactAddress>())

            // Every row still carries its handle. A rename that lost the column would read as an empty
            // string here, which is a refusal that silently stops refusing anything.
            for row in rows {
                #expect(!row.handleKey.isEmpty,
                        "a refusal came back with no handle, so the rename dropped the column's data")
                #expect(!row.scopeId.isEmpty)
                #expect(row.scopeRaw == ContactRefusal.Scope.showRaw
                        || row.scopeRaw == ContactRefusal.Scope.organisationRaw)
            }

            // And they still ANSWER, which is the thing that matters: a row that survived but no longer
            // matched what the importer asks would be a refusal that reads as intact and refuses nothing.
            // Built from the row VALUES rather than through the MainActor helper, so this suite stays
            // non-isolated like the other live-store ones (they must not all be MainActor, which is what
            // #1006's lock exists to serialize across).
            let ledger = ContactRefusal.Ledger(rows: rows.map {
                ContactRefusal.Ledger.Row(scopeRaw: $0.scopeRaw, scopeId: $0.scopeId,
                                          handleKey: $0.handleKey)
            })
            for row in rows where !row.handleKey.hasPrefix("form:") {
                let refused = ledger.isRefused(
                    email: row.handleKey,
                    showKey: row.scopeRaw == ContactRefusal.Scope.showRaw ? row.scopeId : nil,
                    orgKey: row.scopeRaw == ContactRefusal.Scope.organisationRaw ? row.scopeId : nil)
                #expect(refused, "\(row.handleKey) survived the rename but no longer reads as refused")
            }

            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // The claim the rename rests on, asserted rather than argued: what this column stored for an address
    // is byte-identical to what the handle function produces for the same address, so there is no value
    // to migrate. If that ever stops being true, the rename stops being safe and this says so.
    @Test func anAddressKeysTheSameWayItAlwaysDid() {
        for address in ["Ryan@Example.test", "  someone@example.test  ", "Name <person@example.test>"] {
            #expect(ContactRefusal.key(for: address) == ReplyDetection.email(from: address),
                    "the handle for an address differs from what the column already holds")
        }
    }

    @Test func aFormOnlyContactNowHasAKeyAtAll() {
        #expect(ContactRefusal.key(for: nil, formURL: "https://her.example/booking")
                == "form:https://her.example/booking")
        #expect(ContactRefusal.key(for: nil, formURL: nil) == nil, "nothing to name is still nothing")
    }

    // An address always wins over a form, so one contact never has two keys and a refusal made against
    // it before it gained a form is still the refusal that matches it afterwards.
    @Test func anAddressOutranksAFormInTheHandle() {
        #expect(ContactRefusal.key(for: "her@example.test", formURL: "https://her.example/booking")
                == "her@example.test")
    }
}
