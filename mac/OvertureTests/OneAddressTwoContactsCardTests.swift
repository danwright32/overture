import Testing
import Foundation
import SwiftData

// #4589: a card for a show holding two contacts on ONE address.
//
// `Recipient.id` is the contact's email address, not a row identity (#4207), and one show can hold two
// contacts on the same address: #4567 and #4584 found that shape in one send group in Dan's store. The
// card build keyed its per contact lint answers with `Dictionary(uniqueKeysWithValues:)` on that id, so
// building such a card trapped with `Fatal error: Duplicate values for key`, which in the render path
// takes the whole app down rather than drawing one wrong card. Found by the #4357 step 5 agent building
// a facts card store on 2026-10-07.
//
// The assertions are `try #require` on the card's contents, so a wrong card fails one test. A
// regression to the trapping shape itself would still kill the process, which no assertion can catch,
// and that is why the source guard below exists: it refuses the shape before anything runs it.
@MainActor
@Suite("A card for a show with two contacts on one address (#4589)")
struct OneAddressTwoContactsCardTests {
    private static let address = "boxoffice@bargemusic.org"
    // A body the draft lint blocks, so each contact's own lint answer is visible on its snapshot.
    private static let blockedBody = "Hi both, photos are at https://example.com/gallery, let me know."

    private func showWithTwinContacts(_ ctx: ModelContext) throws -> Prospect {
        let p = Prospect(naturalKey: "twin-k", groupName: "Bargemusic", discipline: "classical",
                         venue: "Boathouse", performanceDate: "2099-11-14", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        ctx.insert(p)
        p.writeManualDraft(subject: "Your November dates", body: Self.blockedBody)
        p.addRecipient(Recipient(id: Self.address, email: Self.address, name: "Ada Quill", provenance: .manual))
        p.addRecipient(Recipient(id: Self.address, email: Self.address, name: "Bram Ostrow", provenance: .manual))
        try ctx.save()
        return p
    }

    private var preamble: QueueModel.CardPreamble {
        QueueModel.CardPreamble(linked: [:], inherited: [:],
                                venueBrands: ProducerGate.VenueBrands(shows: [], overrides: .none),
                                rowCounts: [:], calendarBySourceId: [:], overrides: .none,
                                clients: .none, contradictedCancellations: [], sameShowGroups: [:],
                                titlesByKey: [:], collapsedFronts: [:], collapsedHidden: [],
                                laterLookalikesByKey: [:], nightsByKey: [:],
                                now: Date(), day: "2099-03-01")
    }

    // The model path, `QueueModel.card`, which is where the trap was hit.
    @Test func theCardBuildsWithBothContactsAndEachCarriesItsOwnLintAnswer() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let p = try showWithTwinContacts(container.mainContext)
        // The premise: two contacts, one id, both waiting to be sent.
        try #require(p.recipients.count == 2)
        try #require(Set(p.recipients.map(\.id)).count == 1)
        try #require(p.recipients.allSatisfy { $0.sendState == .pending })

        let card = QueueModel.card(p, contacts: nil, preamble: preamble)

        try #require(card.contacts.count == 2, "the card dropped a contact sharing its address with another")
        try #require(Set(card.contacts.compactMap(\.name)) == ["Ada Quill", "Bram Ostrow"])
        try #require(card.draftLintBlockers.contains(.foreignLink),
                     "the card lost the lint finding both contacts' letter carries")
        for contact in card.contacts {
            try #require(contact.isHeldFromSending,
                         "\(contact.name ?? "a contact") was not held by the lint finding its letter carries")
        }
    }

    // The facts path, the same body over `RowFacts`, which is what the engine's facts card store builds
    // from (#4357). Both conform to `ContactFacts`, whose `persistentModelID` is the row identity.
    @Test func theSameCardBuildsFromTheShowsFacts() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let p = try showWithTwinContacts(container.mainContext)
        let facts = RowFacts.extract(p)
        try #require(facts.factContacts.count == 2)

        let fromFacts = QueueModel.card(facts, among: facts.factContacts, preamble: preamble)
        let fromModel = QueueModel.card(p, contacts: nil, preamble: preamble)

        try #require(fromFacts.contacts.count == 2)
        try #require(fromFacts.draftLintBlockers == fromModel.draftLintBlockers)
        try #require(fromFacts.contacts.map(\.isHeldFromSending) == fromModel.contacts.map(\.isHeldFromSending))
    }

    // MARK: - Dan's store

    // How many live shows hold the shape, and that every one of them builds a card carrying each contact.
    // Reads a CLONE taken through `LiveStoreClone` and writes nothing. COUNTS only, never a show or a
    // contact: the line is printed into a log that can reach a pull request. A machine without a live
    // store returns before measuring, which is how every live store suite here skips.
    @Test func everyLiveShowWithTwoContactsOnOneAddressBuildsItsCard() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-4589-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { FileStores.remove(scratch) }
        guard let clone = try LiveStoreClone.makeClone(in: scratch) else { return }
        let container = try FileStores.container(for: AppSchema.schema,
                                                 configurations: [ModelConfiguration(url: clone)])
        let shows = try ModelContext(container).fetch(FetchDescriptor<Prospect>())
        try #require(!shows.isEmpty, "a clone of the live store with no shows in it measured nothing")

        func sharesAnAddress(_ contacts: [Recipient]) -> Bool {
            Set(contacts.map(\.id)).count < contacts.count
        }
        let anyPair = shows.filter { sharesAnAddress($0.recipients) }
        let countedPair = anyPair.filter { sharesAnAddress($0.countedRecipients) }
        // The shape that trapped: two contacts on one address both waiting to be sent.
        let pendingPair = countedPair.filter { sharesAnAddress($0.countedRecipients.filter { $0.sendState == .pending }) }
        print("OneAddressTwoContacts live store: \(shows.count) shows, \(anyPair.count) hold two contacts on one "
              + "address, \(countedPair.count) with both counted, \(pendingPair.count) with both pending")

        for show in countedPair {
            let card = QueueModel.card(show, contacts: nil, preamble: preamble)
            try #require(card.contacts.count == show.countedRecipients.count,
                         "a live show's card dropped a contact sharing its address with another")
        }
    }

    // MARK: - The guard

    // Every `Dictionary(uniqueKeysWithValues:` call in a source text, as the text of its argument, found
    // by balancing parentheses from the call rather than reading a fixed number of lines (L518).
    static func uniquelyKeyedArguments(in text: String) -> [String] {
        let opener = "Dictionary(uniqueKeysWithValues:"
        var out: [String] = []
        var rest = text[...]
        while let start = rest.range(of: opener) {
            var depth = 1
            var index = start.upperBound
            while index < rest.endIndex, depth > 0 {
                switch rest[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                if depth > 0 { index = rest.index(after: index) }
            }
            out.append(String(rest[start.upperBound..<index]))
            rest = index < rest.endIndex ? rest[rest.index(after: index)...] : rest[rest.endIndex...]
        }
        return out
    }

    // True when the argument builds a map over contacts keyed on anything but the row identity. The
    // address (`id`, `email`) repeats across contacts, on one show and across shows, so a uniquely keyed
    // map over it traps the first time two contacts share one. `persistentModelID` is the row identity.
    static func keysContactsOnTheirAddress(_ argument: String) -> Bool {
        let namesContacts = argument.range(of: "recipient|contact|peer|twin",
                                           options: [.regularExpression, .caseInsensitive]) != nil
        guard namesContacts else { return false }
        return !argument.contains("persistentModelID")
    }

    @Test func thePredicateRefusesTheTrappingShapeAndAcceptsTheRowIdentity() {
        let trapping = "let m = Dictionary(uniqueKeysWithValues:\n    pendingRecipients.map { ($0.id, $0.draftLintBlockers(body: body)) })"
        let found = Self.uniquelyKeyedArguments(in: trapping)
        #expect(found.count == 1)
        #expect(found.allSatisfy(Self.keysContactsOnTheirAddress))

        let byIdentity = "Dictionary(uniqueKeysWithValues: contacts.map { ($0.persistentModelID, $0) })"
        #expect(Self.uniquelyKeyedArguments(in: byIdentity).allSatisfy { !Self.keysContactsOnTheirAddress($0) })

        let notContacts = "Dictionary(uniqueKeysWithValues: members.map { ($0.id, nights(of: $0)) })"
        #expect(Self.uniquelyKeyedArguments(in: notContacts).allSatisfy { !Self.keysContactsOnTheirAddress($0) })
    }

    // Derived from the tree rather than a list of call sites (L96), so a new map over contacts anywhere in
    // the app is judged by the same rule.
    @Test func noAppSourceKeysAUniqueMapOnAContactsAddress() {
        var scanned = 0
        var offenders: [String] = []
        for file in AppSourceWalk.files(under: RepoRoot.app) {
            for argument in Self.uniquelyKeyedArguments(in: file.text) {
                scanned += 1
                if Self.keysContactsOnTheirAddress(argument) {
                    offenders.append("\(file.name): Dictionary(uniqueKeysWithValues:"
                        + argument.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                            .joined(separator: " ") + ")")
                }
            }
        }
        // The positive control: the app held four such calls on 2026-10-07 (three in ShowLink, one in
        // the card divergence check), so finding none means the walk measured nothing (L98).
        #expect(scanned >= 3, "found \(scanned) uniquely keyed map(s) in the app, so this measured nothing")
        #expect(offenders.isEmpty, Comment(rawValue: "a uniquely keyed map over contacts keyed on their address "
            + "traps when two contacts share one (#4589); key it on persistentModelID, or merge duplicates "
            + "with Dictionary(_:uniquingKeysWith:) where the address is the right key: "
            + offenders.joined(separator: "; ")))
    }
}
