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
// exceptions. The landing generation is the engine's (#4369, slice E4b) and nothing in the app holds a
// consumer under it until the cutover (#4358, slice E4d), so TODAY'S consumers are listed in
// `waitingOnTheCutover`, each by file and reason, as a ratchet the cutover empties. A consumer not in that list
// is a NEW one, and fails: it is one more surface the cutover would have to find by hand.
//
// WHAT IT CANNOT SEE, stated so a green run is read for what it is (L400):
//   - A call through a VALUE (a stored closure, an injected function, a protocol witness) is not followed, so a
//     write behind one is not found (`StoreWriteScan`'s own list of blind spots).
//   - A consumer that is neither a `@Query` nor a memo input: a view handed the rows and reading them in its
//     body, or a computed property over them. #4370 lists RootView's own readers of `allProspects` among those;
//     they move with the query itself in the cutover, and plan item 3 re-derives them by grep in that PR.
//   - The other direction. A landing that saves a type this list lacks is the A1 real-arm didSave sets'
//     question (#4370), which needs a real landing run and is not asked here.
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

    // TODAY'S CONSUMERS, each held by nothing until the cutover (#4358 slice E4d) moves it onto the engine's
    // landing generation (#4369, slice E4b). The key is the consumer's identity in this scan's own report.
    //
    // Seeded 2026-10-07 from this scan's own report on origin/main 55f71e26: 22 consumers. #4370's hand list named
    // RootView's queries and memo, QueueView's memo, and the WatchedSource queries of FollowUpsView, SourcesView,
    // ScoutSummaryView and AddLeadSheet; the derivation also finds the Archive's and the Sources sheet's memos, the
    // inquiry queries and the inquiry intake sheet, none of which the hand list had (L96).
    private static let queue = "the queue's own read, which the cutover (#4358 slice E4d) replaces with the "
        + "engine's output, published once when the landing generation closes"
    private static let root = "RootView's read, handed to the queue and the sheets; the cutover (#4358 slice "
        + "E4d) deletes it and moves every reader onto the engine's members or a pass output (plan item 3)"
    private static let sheet = "a sheet's own read; the cutover (#4358 slice E4d) moves it onto what the engine "
        + "holds, so it redraws with the landing's one publish rather than once per landed batch"
    static let waitingOnTheCutover: [String: String] = [
        "AddLeadSheet.swift.watched": sheet,
        "ArchiveView.swift.makeScope memo reads prospects": sheet,
        "ArchiveView.swift.makeScope memo reads watchedSources": sheet,
        "ArchiveView.swift.watchedSources": sheet,
        "FollowUpsView.swift.watchedSources": sheet,
        "InquiryIntakeSheet.swift.existing": sheet,
        "QueueView.swift.inquiries": queue,
        "QueueView.swift.makeRenderData memo reads allProspects": queue,
        "QueueView.swift.makeRenderData memo reads inquiries": queue,
        "QueueView.swift.makeRenderData memo reads watchedSources": queue,
        "QueueView.swift.producerTables memo reads allProspects": queue,
        "QueueView.swift.watchedSources": queue,
        "RootView.swift.allInquiries": root,
        "RootView.swift.allProspects": root,
        "RootView.swift.followUpsDue memo reads allInquiries": "the follow ups badge's memo; the cutover (#4358 "
            + "slice E4d) reads the engine's DueWork count and next change instead (D5) and E4e deletes the memo",
        "RootView.swift.followUpsDue memo reads allProspects": "the follow ups badge's memo; the cutover (#4358 "
            + "slice E4d) reads the engine's DueWork count and next change instead (D5) and E4e deletes the memo",
        "RootView.swift.toPrepByStatus": "the prep queue's filtered read; the cutover (#4358 slice E4d) makes "
            + "`toPrep` an output of the engine's pass and deletes the query",
        "RootView.swift.watchedSources": root,
        "ScoutSummaryView.swift.sources": sheet,
        "SourcesView.swift.makeRenderData memo reads prospects": sheet,
        "SourcesView.swift.makeRenderData memo reads sources": sheet,
        "SourcesView.swift.sources": sheet,
    ]

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
        // POSITIVE CONTROLS (L98): the queue's own whole table read and at least one memo input were seen.
        #expect(consumers.contains { $0.key == "RootView.swift.allProspects" }, Comment(rawValue:
            "RootView's prospect query is not among the consumers \(consumers.map(\.key)), so the reader is broken"))
        #expect(consumers.contains { $0.reads.hasPrefix("a memo input") }, Comment(rawValue:
            "no memo input over a landing written type was found, so the memo half measured nothing"))
        print("consumers of what a landing writes: "
              + consumers.map { "\($0.key) (\($0.reads))" }.joined(separator: "; "))

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

// Plan v7 Phase 5 (#4358 item 3): once the queue engine holds the shows and their contacts, no view queries
// either table. Every `@Query` over `Prospect` or `Recipient` in the app is found by the same reader
// `OneQueryPerEntityGuardTests` uses, and the ones the app holds today are listed by file and reason as a ratchet
// the cutover (#4358, slice E4d) empties: a new one fails now, and E4d deletes the list with the queries.
//
// What it does not ask, stated so its silence is not read as more: the plan's second half, a whole-array read of
// the engine's members outside `QueueEngine` and `ShowIdentity`, has nothing to read until the engine publishes
// its members (E4b), so it arrives with them rather than as a guard over a name nothing declares (L1004).
@Suite("No view queries the show or contact tables, apart from today's, which the cutover deletes (#4358)")
struct NoQueryOverShowsOrContactsTests {

    static let tables: Set<String> = ["Prospect", "Recipient"]

    static let waitingOnTheCutover: [String: String] = [
        "RootView.swift.allProspects":
            "the app's one whole table read of the shows, handed to the queue and every sheet. The cutover "
            + "(#4358 slice E4d) deletes it and moves each reader onto the engine's members (plan item 3)",
        "RootView.swift.toPrepByStatus":
            "the prep queue's filtered read (`PrepQueueBuilder.needsPrepPredicate`, #367). The cutover (#4358 "
            + "slice E4d) makes `toPrep` an output of the engine's pass and deletes the query, and E4e the predicate",
    ]

    static func queries(in files: [AppSourceWalk.File]) -> [QueryPairAudit.Declaration] {
        files.flatMap(QueryPairAudit.declarations(in:)).filter { tables.contains($0.entity) }
    }

    @Test func noViewQueriesTheShowOrContactTablesBeyondTodaysOnes() {
        let files = AppSourceWalk.files(under: RepoRoot.app)
        let all = files.flatMap(QueryPairAudit.declarations(in:))
        // POSITIVE CONTROL (L98): the reader sees the app's queries, so an empty finding is about something.
        #expect(all.count > 20, "the reader found only \(all.count) @Query declarations, so it is broken")
        let found = Self.queries(in: files).map { "\($0.file).\($0.property)" }
        #expect(found.contains("RootView.swift.allProspects"), Comment(rawValue:
            "RootView's prospect query was not seen among \(found), so this measured nothing"))
        let unlisted = found.filter { Self.waitingOnTheCutover[$0] == nil }
        #expect(unlisted.isEmpty, Comment(rawValue:
            "@Query over a show or contact table: \(unlisted.sorted().joined(separator: ", ")). The queue engine "
            + "holds these rows (#4358); read them through it rather than through a query of your own, which "
            + "re-reads the table on every store change and redraws mid-landing."))
        let stale = Set(Self.waitingOnTheCutover.keys).subtracting(found)
        #expect(stale.isEmpty, Comment(rawValue:
            "NoQueryOverShowsOrContactsTests.waitingOnTheCutover names queries that are gone: "
            + stale.sorted().joined(separator: ", ") + ". Delete them."))
    }
}
