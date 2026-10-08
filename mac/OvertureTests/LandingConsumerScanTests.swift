import Testing
import Foundation

// #4370 (discussion #4326 B1, decision 8): every surface that reads what a scout landing writes waits for the
// landing's ONE redraw at the end, and the list of those surfaces is DERIVED FROM THE CODE (L96), never kept by
// hand beside it.
//
// TWO DERIVED LISTS, and the second is built from the first.
//
// (a) THE TYPES A LANDING WRITES. Every way into a landing is derived already (`LandingEntryPointsAreDerivedTests`,
// #4343 E0); from each one's whole body this walks every app function it reaches by name, across files, and
// finds every store write in any of them (`StoreWriteScan`, shared with A12, #4329): an assignment to a model
// property, a call to a model method that writes its own row, an `insert(`, a `delete(` and a `save()`. Each
// site is classified in `classified` below with the entity it writes and why. A site the scan finds that the
// table does not hold fails, and so does an entry the scan no longer finds, so the table cannot outlive the
// code it describes. Where the vocabulary can name the entity on its own (a property only one model declares),
// the table has to agree with it, so the table cannot quietly name the wrong one.
//
// (b) THE CONSUMERS OF THOSE TYPES: every `@Query` over one (`QueryPairAudit`'s reader) and every memo input
// over one (`ScopeMemoInputsAreCompleteGuardTests.memoInputs`, the same enumeration that guard asks its own
// question of). Decision 8 says every one of them is held under the landing generation, with no "stays live"
// exceptions. #4358 slice E4d moved every one onto the queue engine: the queue draws its published pass, and every
// other surface reads `QueueEngineRows`, the rows as the engine held them at its last publish, which a landing
// moves once, when it closes. So there are NONE, and a consumer found here is a new query or memo over a table a
// landing writes, which fails: read it through the engine instead.
//
// WHAT IT CANNOT SEE, stated so a green run is read for what it is (L400):
//   - A call through a VALUE (a stored closure, an injected function, a protocol witness) is not followed, so a
//     write behind one is not found (`StoreWriteScan`'s own list of blind spots).
//   - A consumer that is neither a `@Query` nor a memo input: a view handed the rows and reading them in its
//     body, or a computed property over them. Since the cutover those are handed `QueueEngineRows`, but a body
//     that reads a field of one of its rows is still observed for that field, so an open sheet can redraw for a
//     field a landing writes in place. Only the queue's own cards are values (#4371).
//   - The other direction, a landing that saves a type this list lacks, which needs a real landing and is
//     asked in `QueueEngineFullReadNetsTests` over the three entry points that land shows (#4370).
@MainActor
@Suite("Every consumer of what a scout landing writes is named, and the cutover holds each one (#4370)")
struct LandingWrittenTypesScanTests {

    // What a classified site writes.
    enum Writes: Equatable {
        /// A row of this model.
        case entity(String)
        /// Not a model row: a value of the app's own that shares a model property's name. The scan reports those
        /// on purpose, because names are not type checked and over-reporting is the safe direction.
        case notAModelRow
        /// A `save()`, which commits whatever the sites above it wrote and names no type of its own.
        case commits
    }

    struct Classified {
        let writes: Writes
        let why: String
        /// `StoreWriteScan.Site.key`: the function and the kind of write, stable across line drift.
        let sites: [String]
    }

    // THE TABLE. Every store write a landing reaches, grouped by what it writes, each group with why.
    // Seeded 2026-10-07 from the scan's own report on origin/main 55f71e26 (88 keys, 109 sites), each receiver read
    // at its line rather than guessed from the name.
    static let classified: [Classified] = [
        Classified(writes: .entity("Prospect"), why: """
            the shows themselves: a new row is made (`make`, `apply` inserts it) and stamped with how it arrived, a \
            row the feed confirms or misses is reconciled (`FeedReconcile`), a row in a town Dan excluded is retired, \
            a dismissed row the feed brings back is cleared, a Downbeat booking auto-books its show \
            (`markAutoBooked`, which the schema's vocabulary reads as Prospect's own), and the failed turn's rows \
            are deleted when a landing is reverted (`LandingRevert`, whose inserts are the turn's new shows)
            """, sites: [
                "DownbeatBooking.reconcileBooked calls mutator markAutoBooked",
                "ExcludedTownRetirement.run calls mutator markDismissed",
                "FeedReconcile.answerAnyMergeSurvivorQuestion assigns mergeSurvivorUnseenAt",
                "FeedReconcile.answerAnyMergeSurvivorQuestion assigns survivedMergeAt",
                "FeedReconcile.reconcile assigns missedScoutCount",
                "LandingRevert.revert deletes",
                "ScoutService.apply assigns arrivedLookingLike",
                "ScoutService.apply assigns arrivedOnAPitchedNight",
                "ScoutService.apply calls mutator clearDismissal",
                "ScoutService.apply calls mutator setScoutConflict",
                "ScoutService.apply inserts",
                "ScoutService.make assigns disciplineGenreSourceKey",
                "ScoutService.make assigns downbeatClientId",
                "ScoutService.make assigns location",
                "ScoutService.make assigns nightStartTimes",
                "ScoutService.make assigns passedOnThisShow",
                "ScoutService.make assigns performanceStartTimes",
                "ScoutService.make assigns presenterSourceKey",
                "ScoutService.make assigns presenterWasTheRoom",
                "ScoutService.make assigns producerAxisSourceKey",
                "ScoutService.make assigns scoutGroupName",
                "ScoutService.make assigns scoutVenue",
                "ScoutService.make assigns seriesId",
                "ScoutService.make assigns sourceIds",
                "ScoutService.make assigns startTimesVary",
                "ScoutService.make calls mutator setScoutConflict",
            ]),
        Classified(writes: .entity("Inquiry"), why: """
            a direct hire inquiry a Downbeat booking matches: `reconcileBooked` walks shows and inquiries alike, \
            and one that may not auto-book (an inquiry only ever suggests, #1435) has `bookingSuggested` raised. \
            The property is declared by both models, so this entry names the one only this site writes; the \
            Prospect group's `markAutoBooked` already puts shows in the list
            """, sites: [
                "DownbeatBooking.reconcileBooked assigns bookingSuggested",
            ]),
        Classified(writes: .entity("WatchedSource"), why: """
            the feed a landing read: what the read captured is applied in the landing block (`applyCaptured`, \
            #4329), and its health, counts, content hash, pending months and the landing's sequence are stamped
            """, sites: [
                "ScoutExtractIngest.ingest assigns lastLandedRunID",
                "ScoutExtractIngest.ingest assigns lastLandedSequence",
                "ScoutExtractIngest.ingest assigns lastTouchedSequence",
                "ScoutExtractIngest.ingest calls mutator applyCaptured",
                "ScoutExtractIngest.land assigns lastLandedRunID",
                "ScoutExtractIngest.land assigns lastLandedSequence",
                "ScoutExtractIngest.landCaptured assigns lastTouchedSequence",
                "ScoutExtractIngest.landCaptured calls mutator applyCaptured",
                "ScoutExtractIngest.recordPartialCheck assigns failedReadStreak",
                "ScoutExtractIngest.recordPartialCheck assigns hadPlacedBeforeLastRun",
                "ScoutExtractIngest.recordPartialCheck assigns health",
                "ScoutExtractIngest.recordPartialCheck assigns lastCheckedAt",
                "ScoutExtractIngest.recordPartialCheck assigns lastDroppedShowLabels",
                "ScoutExtractIngest.recordPartialCheck assigns lastFailure",
                "ScoutExtractIngest.recordPartialCheck assigns lastPlacedCount",
                "ScoutExtractIngest.recordPartialCheck assigns lastReadableCount",
                "ScoutExtractIngest.recordPartialCheck assigns lastStructuralGapCount",
                "ScoutExtractIngest.recordPartialCheck assigns lastUnreadableCount",
                "ScoutExtractIngest.recordPartialCheck assigns lastUnreadableTitleCount",
                "ScoutExtractIngest.recordSuccess assigns hasUnreadChanges",
                "ScoutExtractIngest.recordSuccess assigns lastContentHash",
                "ScoutExtractIngest.recordSuccess assigns pendingContentHash",
                "ScoutExtractIngest.recordSuccess assigns pendingPageMonths",
                "ScoutExtractIngest.recordSuccess calls mutator recordSuccessfulRead",
                "ScoutService.landNative assigns hasUnreadChanges",
                "ScoutService.landNative assigns lastContentHash",
                "ScoutService.recordCheck calls mutator recordSuccessfulRead",
                "ScoutService.runScout assigns lastLandedRunID",
                "ScoutService.runScout assigns lastLandedSequence",
                "ScoutService.runScout assigns lastManualReadAt",
                "ScoutService.runScout assigns lastTouchedSequence",
                "ScoutService.runScout calls mutator applyCaptured",
            ]),
        Classified(writes: .entity("LandingRun"), why: """
            the landing's own journal row (#4343): opened by `LandingRun.begin`, stamped with its entry flush and \
            when it landed or was recovered, and its recovery attempts counted
            """, sites: [
                "LandingRecovery.recoverNext assigns attemptCount",
                "LandingRun.begin inserts",
                "LeadPasteLanding.landPastedLead assigns entryFlushSaves",
                "LeadPasteLanding.landPastedLead assigns landedAt",
                "ScoutExtractIngest.ingest assigns entryFlushSaves",
                "ScoutExtractIngest.ingest assigns landedAt",
                "ScoutExtractIngest.ingest assigns recoveredAt",
                "ScoutService.runScout assigns entryFlushSaves",
                "ScoutService.runScout assigns landedAt",
            ]),
        Classified(writes: .notAModelRow, why: """
            a value the landing builds before any row is touched, which shares a model property's name: \
            `promoted.venue` and `out.seriesId` on an ExtractedEvent, `p.sourceIds` on the classify pass's own \
            AssembledProspect, and every `enriched.` field `apply` sets on the AssembledProspect it is about to land \
            (read at each line on 55f71e26). A key covers every line of its function, so a later model write to \
            one of these names inside the same function is hidden behind this entry; that is the cost of keying \
            on the function rather than the line, which drifts on every edit
            """, sites: [
                "ExtractedEventGuard.placed assigns venue",
                "SameDateVenueMerge.stamped assigns seriesId",
                "ScoutClassify.run assigns sourceIds",
                "ScoutService.apply assigns conflictKey",
                "ScoutService.apply assigns groupName",
                "ScoutService.apply assigns nightStartTimes",
                "ScoutService.apply assigns partOfRelatedRun",
                "ScoutService.apply assigns performanceDate",
                "ScoutService.apply assigns runEndDate",
                "ScoutService.apply assigns runNights",
                "ScoutService.apply assigns runSourceURLs",
                "ScoutService.apply assigns startTimesVary",
                "ScoutService.apply assigns venue",
            ]),
        Classified(writes: .commits, why: """
            the landing's own saves: the entry flush and the closing save of each entry point, and recovery's
            """, sites: [
                "LandingRecovery.recoverNext saves",
                "LeadPasteLanding.landPastedLead saves",
                "ScoutExtractIngest.ingest saves",
                "ScoutExtractLanding.land saves",
                "ScoutExtractLanding.offerPending saves",
                "ScoutService.runScout saves",
                "ScoutService.saveLanding saves",
            ]),
    ]

    // THE CONSUMERS HELD BY NOTHING, which the cutover (#4358 slice E4d) emptied: it was 22 on 2026-10-07 (origin/main
    // 55f71e26), every one of them RootView's, the queue's and the sheets' own queries and memos, and each now reads
    // the engine. Empty, and kept as the place a reason would have to be written if one were ever allowed.
    static let waitingOnTheCutover: [String: String] = [:]

    // MARK: - (a)

    struct Derivation {
        let entries: [String]
        let sites: [StoreWriteScan.Site]
        let vocabulary: StoreWriteScan.Vocabulary
    }

    static func deriveSites() -> Derivation {
        let files = LandingEntryPointsAreDerivedTests.appFiles()
        let index = StoreWriteScan.Index(files: files)
        let vocabulary = StoreWriteScan.vocabulary(stored: ScoutReadPhaseWriteScanTests.storedByEntity(), index: index)
        let entries = LandingEntryPointsAreDerivedTests.derive(files).entries.map(\.top)
        var sites: Set<StoreWriteScan.Site> = []
        for top in entries {
            let parts = top.split(separator: ".").map(String.init)
            let owner = parts.count > 1 ? parts.dropLast().joined(separator: ".") : nil
            for entry in index.functions(named: parts.last ?? top, owner: owner) {
                let body = index.lines(of: entry)
                sites.formUnion(StoreWriteScan.writes(in: body, file: entry.file, function: entry.qualifiedName,
                                                      vocabulary: vocabulary))
                // The entry's own nested functions are inside its lines already, so only what lies outside them
                // is scanned again.
                let reached = StoreWriteScan.reachable(from: body, file: entry.file, owner: entry.owner, index: index)
                    .filter { $0 != entry && !($0.file == entry.file && $0.firstLine >= entry.firstLine
                                               && $0.lastLine <= entry.lastLine) }
                for function in reached {
                    sites.formUnion(StoreWriteScan.writes(in: index.lines(of: function), file: function.file,
                                                          function: function.qualifiedName, vocabulary: vocabulary))
                }
            }
        }
        return Derivation(entries: entries, sites: sites.sorted { ($0.file, $0.line, $0.key) < ($1.file, $1.line, $1.key) },
                          vocabulary: vocabulary)
    }

    struct Verdict {
        var unclassified: [StoreWriteScan.Site] = []
        var stale: [String] = []
        var classifiedTwice: [String] = []
        var disagreesWithTheVocabulary: [String] = []
        var writtenTypes: Set<String> = []
    }

    // The rule, over a derivation and a table, so it can be driven on sites written here as well as the app's.
    static func judge(_ sites: [StoreWriteScan.Site], vocabulary: StoreWriteScan.Vocabulary,
                      table: [Classified]) -> Verdict {
        var out = Verdict()
        var byKey: [String: Classified] = [:]
        for group in table {
            for key in group.sites {
                if byKey[key] != nil { out.classifiedTwice.append(key) }
                byKey[key] = group
            }
        }
        for site in sites {
            guard let group = byKey[site.key] else {
                out.unclassified.append(site)
                continue
            }
            switch (site.kind, group.writes) {
            case (.saves, .commits):
                break
            case (.saves, _), (_, .commits):
                out.disagreesWithTheVocabulary.append("\(site.key) is classified as \(group.writes)")
            case (.assigns(let name), .entity(let entity)), (.mutator(let name), .entity(let entity)):
                let owners = vocabulary.entities(owning: name)
                if !owners.contains(entity) {
                    out.disagreesWithTheVocabulary.append(
                        "\(site.key) is classified as writing \(entity), and only \(owners) declare \(name)")
                }
                out.writtenTypes.insert(entity)
            case (.inserts, .entity(let entity)), (.deletes, .entity(let entity)):
                out.writtenTypes.insert(entity)
            case (_, .notAModelRow):
                break
            }
        }
        let found = Set(sites.map(\.key))
        out.stale = table.flatMap(\.sites).filter { !found.contains($0) }.sorted()
        return out
    }

    // MARK: - (b)

    struct Consumer: Hashable {
        let key: String
        let reads: String
    }

    static func consumers(of written: Set<String>) -> [Consumer] {
        let files = AppSourceWalk.files(under: RepoRoot.app)
        var out: Set<Consumer> = []
        for declaration in files.flatMap(QueryPairAudit.declarations(in:)) where written.contains(declaration.entity) {
            out.insert(Consumer(key: "\(declaration.file).\(declaration.property)",
                                reads: "@Query over \(declaration.entity)"))
        }
        let models = ScopeMemoInputsAreCompleteGuardTests.modelTypes()
        for input in ScopeMemoInputsAreCompleteGuardTests.memoInputs(models: models).inputs
        where written.contains(input.element) {
            out.insert(Consumer(key: "\(input.file).\(input.derivation) memo reads \(input.collection)",
                                reads: "a memo input over \(input.element)"))
        }
        return out.sorted { $0.key < $1.key }
    }

    // MARK: - The question asked of the app

    @Test func everyStoreWriteALandingReachesIsClassified() {
        let derived = Self.deriveSites()
        // POSITIVE CONTROLS (L98): the entry points were derived, the walk found the writes a landing is known to
        // make, and the vocabulary was read, so an empty table of findings cannot read as a landing that writes
        // nothing.
        #expect(derived.entries.contains("ScoutService.runScout"), Comment(rawValue:
            "the landing entry points derived as \(derived.entries), without runScout, so nothing below was measured"))
        #expect(derived.sites.contains { $0.kind == .inserts && $0.function == "ScoutService.apply" }, Comment(rawValue:
            "no insert was found in ScoutService.apply, where every landed show is created, so the walk is not "
            + "reaching the landing"))
        let verdict = Self.judge(derived.sites, vocabulary: derived.vocabulary, table: Self.classified)
        print("landing writes \(derived.sites.count) sites over \(Set(derived.sites.map(\.key)).count) keys, "
              + "types: \(verdict.writtenTypes.sorted().joined(separator: ", "))")
        #expect(verdict.unclassified.isEmpty, Comment(rawValue:
            "store writes a landing reaches that LandingWrittenTypesScanTests.classified does not hold: "
            + Set(verdict.unclassified.map(\.key)).sorted().joined(separator: "; ")
            + ". Classify each with the type it writes and why, so the consumers of that type are found (#4370)."))
        #expect(verdict.stale.isEmpty, Comment(rawValue:
            "classified sites the scan no longer finds: " + verdict.stale.joined(separator: "; ")
            + ". Delete the entry, so the table cannot outlive the code it describes."))
        #expect(verdict.classifiedTwice.isEmpty, Comment(rawValue:
            "sites classified in more than one group: \(verdict.classifiedTwice)"))
        #expect(verdict.disagreesWithTheVocabulary.isEmpty, Comment(rawValue:
            verdict.disagreesWithTheVocabulary.joined(separator: "; ")))
        for known in ["Prospect", "WatchedSource", "LandingRun"] {
            #expect(verdict.writtenTypes.contains(known), Comment(rawValue:
                "the types a landing writes were derived as \(verdict.writtenTypes.sorted()), without \(known)"))
        }
    }

    @Test func everyConsumerOfALandingWrittenTypeIsOneTheCutoverHolds() {
        let derived = Self.deriveSites()
        let written = Self.judge(derived.sites, vocabulary: derived.vocabulary, table: Self.classified).writtenTypes
        let consumers = Self.consumers(of: written)
        // POSITIVE CONTROLS (L98): the readers really read the app, so an empty finding is about something. Each
        // reader finds queries and memo inputs over the app's OTHER tables, and finds a planted one over a landing
        // written type (`theReadersFindAPlantedConsumer`).
        #expect(written.contains("Prospect"), "the derived written types \(written.sorted()) lack Prospect")
        let everyQuery = AppSourceWalk.files(under: RepoRoot.app).flatMap(QueryPairAudit.declarations(in:))
        #expect(everyQuery.count > 10, "the query reader found \(everyQuery.count) queries, so it is broken")
        let everyMemoInput = ScopeMemoInputsAreCompleteGuardTests.memoInputs(
            models: ScopeMemoInputsAreCompleteGuardTests.modelTypes()).inputs
        #expect(!everyMemoInput.isEmpty, "the memo reader found no memo input at all, so it is broken")
        print("consumers of what a landing writes: "
              + (consumers.isEmpty ? "none" : consumers.map { "\($0.key) (\($0.reads))" }.joined(separator: "; ")))

        let unheld = consumers.filter { Self.waitingOnTheCutover[$0.key] == nil }
        #expect(unheld.isEmpty, Comment(rawValue:
            "consumers of a type a scout landing writes that nothing holds until the landing's one redraw: "
            + unheld.map { "\($0.key) (\($0.reads))" }.joined(separator: "; ")
            + ". Each one redraws mid-landing, against decision 8 (#4370). Read through the queue engine, which "
            + "holds its outputs under the landing generation (#4369), rather than adding a query or memo over it."))
        let stale = Set(Self.waitingOnTheCutover.keys).subtracting(consumers.map(\.key))
        #expect(stale.isEmpty, Comment(rawValue:
            "LandingWrittenTypesScanTests.waitingOnTheCutover names consumers the scan no longer finds: "
            + stale.sorted().joined(separator: "; ") + ". Delete them, so the list shrinks to empty at the cutover."))
        for (consumer, why) in Self.waitingOnTheCutover {
            #expect(why.contains("E4d"), Comment(rawValue:
                "\(consumer) is allowed with a reason that names no change to end it: \(why)"))
        }
    }

    // MARK: - The rule, on sites written here

    @Test func theRuleRefusesAnUnclassifiedSiteAStaleEntryAndAWrongType() {
        let files: [(name: String, text: String)] = [
            (name: "Domain/Show.swift", text: """
                @Model final class Show {
                    var title: String = ""
                }
                @Model final class Feed {
                    var health: String = ""
                }
                """),
            (name: "Integration/Land.swift", text: """
                enum Land {
                    static func land(context: ModelContext, show: Show, feed: Feed) {
                        show.title = "x"
                        feed.health = "ok"
                        context.insert(show)
                        try? context.save()
                    }
                }
                """),
        ]
        let index = StoreWriteScan.Index(files: files)
        let vocabulary = StoreWriteScan.vocabulary(stored: ["Show": ["title"], "Feed": ["health"]], index: index)
        guard let land = index.functions(named: "land", owner: "Land").first else {
            Issue.record("the fixture's landing function was not indexed")
            return
        }
        let sites = StoreWriteScan.writes(in: index.lines(of: land), file: land.file, function: land.qualifiedName,
                                          vocabulary: vocabulary)
        let complete: [Classified] = [
            Classified(writes: .entity("Show"), why: "the show", sites: ["Land.land assigns title", "Land.land inserts"]),
            Classified(writes: .entity("Feed"), why: "the feed", sites: ["Land.land assigns health"]),
            Classified(writes: .commits, why: "the save", sites: ["Land.land saves"]),
        ]
        let clean = Self.judge(sites, vocabulary: vocabulary, table: complete)
        #expect(clean.unclassified.isEmpty && clean.stale.isEmpty && clean.disagreesWithTheVocabulary.isEmpty)
        #expect(clean.writtenTypes == ["Show", "Feed"])

        // A site the table does not hold.
        let missing = Self.judge(sites, vocabulary: vocabulary, table: Array(complete.dropFirst()))
        #expect(Set(missing.unclassified.map(\.key)) == ["Land.land assigns title", "Land.land inserts"])
        // An entry the scan no longer finds.
        let stale = Self.judge(sites, vocabulary: vocabulary, table: complete + [
            Classified(writes: .notAModelRow, why: "gone", sites: ["Land.gone assigns title"])])
        #expect(stale.stale == ["Land.gone assigns title"])
        // A type the vocabulary says the property does not belong to.
        let wrong = Self.judge(sites, vocabulary: vocabulary, table: [
            Classified(writes: .entity("Show"), why: "wrong", sites: ["Land.land assigns health", "Land.land inserts",
                                                                     "Land.land assigns title"]),
            Classified(writes: .commits, why: "the save", sites: ["Land.land saves"]),
        ])
        #expect(wrong.disagreesWithTheVocabulary.count == 1, Comment(rawValue: "\(wrong.disagreesWithTheVocabulary)"))
        // A save classified as a type, and a type write classified as a save.
        let crossed = Self.judge(sites, vocabulary: vocabulary, table: [
            Classified(writes: .entity("Show"), why: "x", sites: ["Land.land saves", "Land.land inserts"]),
            Classified(writes: .commits, why: "x", sites: ["Land.land assigns title", "Land.land assigns health"]),
        ])
        #expect(crossed.disagreesWithTheVocabulary.count == 3, Comment(rawValue: "\(crossed.disagreesWithTheVocabulary)"))
        // The same site in two groups.
        let twice = Self.judge(sites, vocabulary: vocabulary, table: complete + [
            Classified(writes: .commits, why: "again", sites: ["Land.land saves"])])
        #expect(twice.classifiedTwice == ["Land.land saves"])
    }
}

// Plan v7 Phase 5 (#4358 item 3): the queue engine holds the shows and their contacts, so no view queries either
// table. Every `@Query` over `Prospect` or `Recipient` in the app is found by the same reader
// `OneQueryPerEntityGuardTests` uses, and there are none: the cutover (#4358 slice E4d) deleted RootView's two, the
// last ones, and any query found here fails, no exemptions.
@Suite("No view queries the show or contact tables (#4358)")
struct NoQueryOverShowsOrContactsTests {

    static let tables: Set<String> = ["Prospect", "Recipient"]

    static func queries(in files: [AppSourceWalk.File]) -> [QueryPairAudit.Declaration] {
        files.flatMap(QueryPairAudit.declarations(in:)).filter { tables.contains($0.entity) }
    }

    @Test func noViewQueriesTheShowOrContactTables() {
        let files = AppSourceWalk.files(under: RepoRoot.app)
        let all = files.flatMap(QueryPairAudit.declarations(in:))
        // POSITIVE CONTROL (L98): the reader sees the app's queries, so an empty finding is about something.
        #expect(all.count > 10, "the reader found only \(all.count) @Query declarations, so it is broken")
        let found = Self.queries(in: files).map { "\($0.file).\($0.property)" }
        #expect(found.isEmpty, Comment(rawValue:
            "@Query over a show or contact table: \(found.sorted().joined(separator: ", ")). The queue engine "
            + "holds these rows (#4358); read them through it (`QueueEngineRows`, or the engine as a ShowResolver) "
            + "rather than a query of your own, which re-reads the table on every store change and redraws "
            + "mid-landing."))
    }

    // The reader finds a query over the show table when there is one, so the empty answer above is a finding.
    @Test func theReaderFindsAPlantedShowQuery() {
        let planted = AppSourceWalk.File(url: URL(fileURLWithPath: "/planted/Planted.swift"), name: "Planted.swift",
                                         text: """
            struct Planted: View {
                @Query private var shows: [Prospect]
                var body: some View { Text("\\(shows.count)") }
            }
            """)
        #expect(Self.queries(in: [planted]).map(\.property) == ["shows"])
    }
}

// Plan v7 Phase 5 (#4358 item 3, the cutover, slice E4d): the surfaces that still read a WHOLE ARRAY of the queue
// engine's members (`everyShow`, `everyInquiry`, `everySource`, on the engine as a `ShowResolver` or on the
// `QueueEngineRows` it hands out) are listed here by file and declaration, each until #4359 gives it an output of its
// own, and a NEW one fails. A whole array read is the shape that turns one change into a walk of every show, and the
// engine exists so a surface reads what changed; every one added later is a surface #4359 would have to find by hand.
//
// Keyed on the type member that holds the read (the nearest declaration at member indentation), so line drift moves
// nothing. The engine itself, `ShowIdentity` (the protocol's own default answers) and `QueueEngineHost` (which builds
// the rows) are the members' owners, not readers, and are not scanned.
//
// WHAT IT CANNOT SEE (L400): a read through a value (a closure or a protocol witness handed the array), and a read in
// a nested type's member, which keys on the outer member's name.
@Suite("No new surface reads the queue engine's members whole (#4358, #4359)")
struct EngineMembersReadWholeTests {

    static let owners: Set<String> = ["QueueEngine.swift", "ShowIdentity.swift", "QueueEngineHost.swift"]

    private static let phase6 = "reads the engine's members whole until #4359 gives this surface an output of its own"
    static let waitingOnPhase6: [String: String] = [
        "ArchiveView.swift.makeScope": "the Archive's scope over every show; " + phase6,
        "ArchiveView.swift.prospects": "the Archive's actions over every show; " + phase6,
        "ProspectMutations.swift.bulkReprep": "the bulk re-prep over every show; " + phase6,
        "ProspectMutations.swift.bulkReprepEligible": "the bulk re-prep's gate over every show; " + phase6,
        "ProspectMutations.swift.manualPrepPrefill": "a show's other rows' past addresses; " + phase6,
        "ProspectMutations.swift.setOrgDoNotContact": "an organisation's other shows; " + phase6,
        "QueueView.swift.actionItems": "a press's whole queue card question (clashes, jumps); " + phase6,
        "QueueView.swift.body": "the inquiry edit sheet's duplicate check; " + phase6,
        "QueueView.swift.inquiryRowView": "an inquiry press finding its inquiry; " + phase6,
        "QueueView.swift.navigateToLead": "a deep link's Reached out entries; " + phase6,
        "QueueView.swift.prospects": "the queue's actions over its scope; " + phase6,
        "RootView.swift.allItems": "the Prep selection sheet's cards; " + phase6,
        "RootView.swift.allRows": "the search bar's Archive half; " + phase6,
        "RootView.swift.debugStageFirstAsSent": "a Debug helper picking a show; " + phase6,
        "RootView.swift.eligibleForBulkReprep": "the bulk re-prep menu's gate; " + phase6,
        "RootView.swift.nonDismissedProspects": "the search bar's scope and deep link routing; " + phase6,
        "RootView.swift.queueSurface": "the Add lead sheet's watchlist; " + phase6,
        "RootView.swift.refreshUnreadableFiles": "the bounced pitch notice; " + phase6,
        "RootView.swift.sourcesNeedingALook": "the Sources button's count; " + phase6,
        "RootView.swift.withSheets": "the sheets' rows; " + phase6,
        "SourcesView.swift.makeRenderData": "the Sources sheet's pass; " + phase6,
        // The Sources sheet's two reads (its shows and its watchlist) were two properties of its own until slice E4d
        // handed it the engine's rows (`held`); the same two reads now sit in the members that use them.
        "SourcesView.swift.body": "the Sources sheet's watchlist, empty or not; " + phase6,
        "SourcesView.swift.recomputeCalendarClients": "the Sources sheet's client coverage over the watchlist; " + phase6,
        "SourcesView.swift.renderTrace": "the Sources sheet's Debug trace of its two counts; " + phase6,
        "SourcesView.swift.roomContext": "the Sources sheet's client window over the watchlist; " + phase6,
    ]

    private static let read = try! NSRegularExpression(pattern: #"\.(everyShow|everyInquiry|everySource)\b"#)
    private static let member = try! NSRegularExpression(
        pattern: #"^ {4}(?:@\w+\s+)*(?:(?:private|fileprivate|internal|static|nonisolated|override|mutating)\s+)*(?:func|var)\s+(\w+)"#)

    /// Every whole array read of the members, keyed "File.swift.member".
    static func readers(in files: [AppSourceWalk.File]) -> Set<String> {
        var out: Set<String> = []
        for file in files where !owners.contains(file.name) {
            let lines = file.text.components(separatedBy: "\n").map { $0.components(separatedBy: "//")[0] }
            for (index, line) in lines.enumerated()
            where read.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                var name = "?"
                for upward in stride(from: index, through: 0, by: -1) {
                    let candidate = lines[upward]
                    if let m = member.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
                       let r = Range(m.range(at: 1), in: candidate) {
                        name = String(candidate[r])
                        break
                    }
                }
                out.insert("\(file.name).\(name)")
            }
        }
        return out
    }

    @Test func noNewSurfaceReadsTheMembersWhole() {
        let found = Self.readers(in: AppSourceWalk.files(under: RepoRoot.app))
        // POSITIVE CONTROL (L98): RootView's sheets read the rows whole today, so the reader is reaching the app.
        #expect(found.contains("RootView.swift.withSheets"), Comment(rawValue:
            "the reader did not see RootView's sheets among \(found.sorted()), so it measured nothing"))
        let unlisted = found.subtracting(Self.waitingOnPhase6.keys)
        #expect(unlisted.isEmpty, Comment(rawValue:
            "new whole array reads of the queue engine's members: \(unlisted.sorted().joined(separator: ", ")). "
            + "Read what the engine publishes for this surface, or resolve the one show through the engine "
            + "(`ShowIdentity`), rather than walking every member (#4358, #4359)."))
        let stale = Set(Self.waitingOnPhase6.keys).subtracting(found)
        #expect(stale.isEmpty, Comment(rawValue:
            "EngineMembersReadWholeTests.waitingOnPhase6 names readers that are gone: "
            + stale.sorted().joined(separator: ", ") + ". Delete them, so the list only shrinks."))
    }

    @Test func theReaderNamesTheMemberAPlantedReadSitsIn() {
        let planted = AppSourceWalk.File(url: URL(fileURLWithPath: "/planted/Planted.swift"), name: "Planted.swift",
                                         text: """
            struct Planted {
                private func countEverything() -> Int {
                    let all = engine.everyShow
                    return all.count
                }
                // a comment naming .everyShow is not a read
            }
            """)
        #expect(Self.readers(in: [planted]) == ["Planted.swift.countEverything"])
    }
}

// #4358 slice E4d, carried over from `OneWholeTableProspectQueryTests`, which the cutover deleted with the query it
// ratcheted (L430: the query ratchet's premise was consumed, these two claims were not). Every surface RootView
// presents takes the rows the queue engine holds, and none gives what it takes a DEFAULT.
//
// A default is not an untidiness here: a caller that forgets the argument renders an empty sheet, and an empty sheet
// is exactly what an empty store looks like, so the failure is silent and total (L168, L67). And the call site is
// asserted, not only the absence of a query in the sheet, because a sheet handed something OTHER than the engine's
// rows would compile (L3).
@Suite("Every surface RootView presents takes the engine's rows, with no default (#3871, #4358)")
struct TheSheetsTakeTheEnginesRowsTests {

    /// Each surface's file and the one stored declaration it takes its rows by.
    static let declarations: [(file: String, declaration: String)] = [
        ("QueueView.swift", "let engine: QueueEngineHost.Engine"),
        ("ArchiveView.swift", "let rows: QueueEngineRows"),
        ("SourcesView.swift", "let held: QueueEngineRows"),
        ("OutcomePatternsView.swift", "let prospects: [Prospect]"),
        ("WrittenOffBacklogSection.swift", "let prospects: [Prospect]"),
        ("EmptyAnswerSection.swift", "let prospects: [Prospect]"),
        ("ExperimentReportView.swift", "let prospects: [Prospect]"),
        ("FollowUpsView.swift", "let prospects: [Prospect]"),
        ("OrganisationsView.swift", "let prospects: [Prospect]"),
        ("StruckAddressesView.swift", "let prospects: [Prospect]"),
    ]

    /// RootView's call sites, each handing the engine's rows, and OutcomePatternsView's, handing on its own.
    static let rootCalls = [
        "QueueView(engine: engine,", "ArchiveView(rows: rows,", "SourcesView(held: rows,",
        "OutcomePatternsView(prospects: rows.everyShow)", "FollowUpsView(prospects: rows.everyShow,",
        "StruckAddressesView(prospects: rows.everyShow)", "OrganisationsView(prospects: rows.everyShow,",
    ]
    static let patternsCalls = [
        "EmptyAnswerSection(prospects: prospects)", "WrittenOffBacklogSection(prospects: prospects)",
        "ExperimentReportView(prospects: prospects)",
    ]

    /// Every uncommented line declaring `name` with `type` as storage, a computed property (a brace) excluded.
    static func storedDeclarations(of name: String, type: String, in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.contains("{") }
            .filter { $0.contains("\(name): \(type)") }
    }

    @Test func eachSurfaceTakesItsRowsAsALetWithNoDefault() throws {
        let app = AppSourceWalk.appFiles()
        for (fileName, declaration) in Self.declarations {
            let file = try #require(app.first { $0.name == fileName }, "\(fileName) was not found in the app")
            let parts = declaration.dropFirst("let ".count).split(separator: ":", maxSplits: 1)
            let name = String(parts[0])
            let type = parts[1].trimmingCharacters(in: .whitespaces)
            let found = Self.storedDeclarations(of: name, type: type, in: file.text)
            // The positive control: a file where the declaration cannot be found would pass every claim below while
            // checking nothing (L98).
            #expect(found.count == 1, Comment(rawValue:
                "\(fileName) holds \(found.count) stored declarations of `\(name): \(type)`, not one, so this cannot "
                + "say whether it carries a default"))
            for line in found {
                let carriesADefault = line.contains("=")
                #expect(!carriesADefault, Comment(rawValue:
                    "\(fileName) gives its handed-down rows a default. A caller that forgets them then renders an "
                    + "empty screen that looks exactly like an empty store"))
                let isALet = line.hasPrefix("let ")
                #expect(isALet, Comment(rawValue:
                    "\(fileName) declares its handed-down rows as something other than a `let`, so they can be "
                    + "given a default or reassigned after the view is built"))
            }
        }
    }

    @Test func rootViewHandsEachSurfaceTheEnginesRows() throws {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!root.isEmpty, "RootView.swift could not be read, so nothing below was measured")
        for call in Self.rootCalls {
            // Bound to a Bool first, so a failure prints the sentence rather than the file (L445).
            let hands = SourceGuardHelper.containsCode(call, in: root)
            #expect(hands, Comment(rawValue:
                "RootView no longer hands the engine's rows through `\(call)`, so that surface draws from something "
                + "other than what the queue engine holds"))
        }
        let patterns = SourceGuardHelper.source("Overture/UI/OutcomePatternsView.swift")
        for call in Self.patternsCalls {
            let passes = SourceGuardHelper.containsCode(call, in: patterns)
            #expect(passes, Comment(rawValue: "OutcomePatternsView no longer passes its rows to \(call)"))
        }
    }

    // The reader sees a default when one is there, so the clean answer above is a finding.
    @Test func theReaderSeesAPlantedDefault() {
        let text = """
            struct Planted: View {
                let prospects: [Prospect] = []
                private var count: [Prospect] { prospects }
            }
            """
        let found = Self.storedDeclarations(of: "prospects", type: "[Prospect]", in: text)
        #expect(found == ["let prospects: [Prospect] = []"])
    }
}
