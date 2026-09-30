import Testing
import Foundation
import SwiftData

// #4328 (step A1 of #4275's plan): the landing oracle's tests. See `LandingOracle.swift` for what the oracle
// is, which view it reads and what it leaves out. A step toward #4275; the 100 ms bar is not met.
//
// THIS FILE, `LandingOracle.swift` and `LandingOracleCorpus.swift` are the WHOLE overlay the oracle script
// (`scripts/landing-oracle.sh`) copies onto a worktree of 6d3453d8, so they may use only what 6d3453d8
// already has. That is what makes "the expected values come from 6d3453d8" true rather than asserted: the
// script builds this code against the OLD app and records what it says (L70, L58).
//
// Environment, all read with the runner's TEST_RUNNER_ prefix stripped:
//
//   LANDING_ORACLE_RECORD_SYNTHETIC=<file>   write the synthetic snapshot there instead of comparing
//   MEASURE_4275=1 MEASURE_4275_INPUTS=<archive> MEASURE_4275_OUT=<dir> LANDING_ORACLE_MODE=record|compare
//                                            the real arm, on the frozen inputs, opt in
//   FREEZE_4275_TO=<dir>                     build the frozen inputs (#4327 step 0.0), opt in
// A `final class`, not a struct, because `TemporarySandboxes` removes what it made when its owner is released,
// and a struct suite is never released as an object: the real arm's copies of real data would outlive the run.
@MainActor
@Suite("The scout landing oracle (#4328, step A1 of #4275)", .serialized)
final class LandingOracleTests {

    private let sandboxes = TemporarySandboxes()

    nonisolated static var env: [String: String] { ProcessInfo.processInfo.environment }

    static let syntheticFixture = "fixtures/landing-oracle/synthetic-6d3453d8.txt"

    // MARK: the corpus holds every case

    private typealias Entry = (url: String, title: String, venue: String)

    private static func urlEntries(_ title: String, _ venue: String, _ urls: [String]) -> [Entry] {
        ListingURL.foldedSet(urls).sorted().map { (url: $0, title: title, venue: ShowLink.foldedVenue(venue)) }
    }

    private static func tokenEntries(_ title: String, _ venue: String, _ urls: [String])
        -> [(token: String, title: String, venue: String)] {
        urls.compactMap(ProductionToken.inURL).map {
            (token: $0, title: ShowLink.foldedTitle(title), venue: ShowLink.foldedVenue(venue))
        }
    }

    /// The order the landing meets the URL entries in: the stored rows first, then each source's events in the
    /// order the results file lists them.
    private static func arrivalEntries(order: [String]) -> [Entry] {
        let stored = LandingOracleCorpus.stored.flatMap {
            urlEntries($0.title, $0.venue, [$0.listingURL] + $0.runURLs)
        }
        let byId = Dictionary(uniqueKeysWithValues: LandingOracleCorpus.sources.map { ($0.id, $0) })
        let incoming = order.compactMap { byId[$0] }.flatMap { source in
            source.events.flatMap { urlEntries($0.title, $0.venue ?? "", [$0.sourceUrl ?? ""]) }
        }
        return stored + incoming
    }

    static let fenwickSwapped: [String] = {
        var ids = LandingOracleCorpus.sources.map(\.id)
        let a = ids.firstIndex(of: "oracle-fenwick-a")!
        let b = ids.firstIndex(of: "oracle-fenwick-b")!
        ids.swapAt(a, b)
        return ids
    }()

    @Test func theCorpusHoldsEveryCaseTheOracleExistsFor() {
        let corpus = LandingOracleCorpus.self
        let harbor = corpus.sources.first { $0.id == "oracle-harbor" }!

        // A production token poisoned at ONE venue: two distinct folded titles under one token and venue.
        let harborTokens = harbor.events.flatMap { Self.tokenEntries($0.title, $0.venue ?? "", [$0.sourceUrl ?? ""]) }
        let underPoisoned = Set(harborTokens.filter { $0.token == corpus.poisonedToken }.map(\.title))
        #expect(underPoisoned.count == 2 && ShowLink.poisonedTokens(harborTokens).contains(corpus.poisonedToken),
                Comment(rawValue: "the corpus lost its poisoned token: \(underPoisoned.count) folded titles "
                        + "under it at one venue"))

        // The non-transitive triple: the middle title matches both ends, the ends do not match each other.
        let (a, b, c) = (corpus.tripleEnds[0], corpus.tripleEnds[1], corpus.tripleMiddle)
        #expect(GroupNameMatch.isSameShowTitle(a, c) && GroupNameMatch.isSameShowTitle(b, c)
                && !GroupNameMatch.isSameShowTitle(a, b),
                Comment(rawValue: "the triple is no longer non-transitive under isSameShowTitle"))

        // ...and its ARRIVAL ORDER changes how many shows its URL holds, which is what makes addShows order
        // dependent. Folded in the corpus's order and again with the two Fenwick sources swapped.
        let key = ListingURL.foldedSet([corpus.tripleURL]).first! + "|" + ShowLink.foldedVenue(corpus.tripleVenue)
        func showsAtTheTriple(_ order: [String]) -> Int {
            var shows: [String: [String]] = [:]
            ShowLink.addShows(Self.arrivalEntries(order: order), scopedByVenue: true, into: &shows)
            return shows[key]?.count ?? 0
        }
        let inOrder = showsAtTheTriple(corpus.sources.map(\.id))
        let swapped = showsAtTheTriple(Self.fenwickSwapped)
        #expect(inOrder != swapped && inOrder > 0 && swapped > 0, Comment(rawValue:
            "the triple's URL holds \(inOrder) shows in the corpus order and \(swapped) with the two Fenwick "
            + "sources swapped, so the corpus no longer exercises the order dependent fold"))

        // An ambiguous URL: one page listing two different shows at one venue.
        let ambiguous = ShowLink.ambiguousURLs(Self.arrivalEntries(order: corpus.sources.map(\.id)),
                                               scopedByVenue: true)
        #expect(ambiguous.contains(ListingURL.foldedSet([corpus.ambiguousURL]).first!),
                Comment(rawValue: "the corpus lost its ambiguous URL"))

        // A spelling decision: the source's own stored spelling wins over one slip away from it.
        let used = corpus.stored.filter { $0.sourceIds.contains(corpus.spellingSource) }.map(\.venue)
        let locked = VenueSpellingLock.locked(corpus.spellingIncoming, spellingsUsedBySource: used)
        #expect(locked == corpus.spellingStored && corpus.spellingIncoming != corpus.spellingStored,
                Comment(rawValue: "the spelling lock no longer changes the incoming spelling (it gave \(locked ?? "nil"))"))

        // The stripped-key case: a token ambiguous at a venue only STORED rows hold, arriving in a batch at a
        // different venue, is still poisoned for that batch, and the batch alone would not poison it.
        let storedTokens = corpus.stored.flatMap { Self.tokenEntries($0.title, $0.venue, [$0.listingURL]) }
        let quarry = corpus.sources.first { $0.id == "oracle-quarry" }!
        let batchTokens = quarry.events.flatMap { Self.tokenEntries($0.title, $0.venue ?? "", [$0.sourceUrl ?? ""]) }
        let batchVenues = Set(batchTokens.filter { $0.token == corpus.strippedToken }.map(\.venue))
        #expect(!batchVenues.isEmpty && !batchVenues.contains(ShowLink.foldedVenue(corpus.strippedStoredVenue)),
                Comment(rawValue: "the stripped-key batch no longer carries the token at a different venue"))
        #expect(ShowLink.poisonedTokens(storedTokens + batchTokens).contains(corpus.strippedToken)
                && !ShowLink.poisonedTokens(batchTokens).contains(corpus.strippedToken),
                Comment(rawValue: "the stripped-key token is not poisoned only by the stored rows"))
    }

    // MARK: the synthetic arm against its recording from 6d3453d8

    @Test func theSyntheticLandingEqualsTheOracleRecordedFromMain() async throws {
        let container = try await LandingOracleCorpus.land()
        let snapshot = try LandingOracle.snapshot(of: container)
        #expect((snapshot.counts["Prospect"] ?? 0) >= 50, Comment(rawValue:
            "the synthetic landing left \(snapshot.counts["Prospect"] ?? 0) shows, far fewer than the corpus "
            + "holds, so it is not landing what it claims to"))

        if let target = Self.env["LANDING_ORACLE_RECORD_SYNTHETIC"] {
            let text = LandingOracle.syntheticFile(snapshot, header: [
                "#4328 synthetic landing oracle. GENERATED by scripts/landing-oracle.sh from a worktree of the",
                "commit named in the file name; never edit by hand. Invented data only. Clock-derived fields",
                "are excluded (LandingOracle.clockDerived). Read through a fresh ModelContext after one save.",
            ])
            try text.write(to: URL(fileURLWithPath: target), atomically: true, encoding: .utf8)
            print("landing-oracle: RECORDED synthetic arm, \(snapshot.rows.count) rows, digest "
                  + LandingOracle.digest(of: snapshot))
            return
        }
        let url = RepoRoot.url.appendingPathComponent(Self.syntheticFixture)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record(Comment(rawValue: "no recorded synthetic oracle at \(Self.syntheticFixture); record it "
                                 + "with scripts/landing-oracle.sh"))
            return
        }
        let differences = LandingOracle.differences(expected: LandingOracle.parse(text), actual: snapshot,
                                                    arm: .synthetic)
        #expect(differences.isEmpty, Comment(rawValue:
            "the synthetic landing no longer leaves what 6d3453d8 left:\n" + differences.joined(separator: "\n")))
    }

    // MARK: the clock-derived list, derived

    @Test func everyFieldThatDiffersBetweenTwoLandingsIsAClockField() async throws {
        let first = try LandingOracle.snapshot(of: await LandingOracleCorpus.land())
        let second = try LandingOracle.snapshot(of: await LandingOracleCorpus.land())
        // Excluded fields are gone from both, so what remains must be identical: the landing is deterministic
        // over everything the oracle compares.
        let drift = LandingOracle.differences(expected: LandingOracle.recording(of: first), actual: second,
                                              arm: .synthetic)
        #expect(drift.isEmpty, Comment(rawValue:
            "two landings of the same inputs differ in a field the oracle compares, so either a clock field is "
            + "missing from LandingOracle.clockDerived or the landing is not deterministic:\n"
            + drift.joined(separator: "\n")))

        // And the list itself is measured, not trusted: with nothing excluded, the fields that differ between
        // the two landings must all be on it, and at least one must differ, or this could not see a clock
        // stamp at all (L159).
        let unexcludedA = try Self.unexcluded(await LandingOracleCorpus.land())
        let unexcludedB = try Self.unexcluded(await LandingOracleCorpus.land())
        var differing = Set<String>()
        for (rowA, rowB) in zip(unexcludedA, unexcludedB) where rowA.entity == rowB.entity {
            for (fa, fb) in zip(rowA.fields, rowB.fields) where fa.name == fb.name && fa.value != fb.value {
                differing.insert("\(rowA.entity).\(fa.name)")
            }
        }
        #expect(differing.contains("Prospect.ingestedAt"), Comment(rawValue:
            "two landings did not differ even in ingestedAt, so this cannot see a clock stamp (found \(differing.sorted()))"))
        let unlisted = differing.subtracting(LandingOracle.clockDerived.keys)
        #expect(unlisted.isEmpty, Comment(rawValue:
            "fields that differ between two landings of the same inputs and are not in "
            + "LandingOracle.clockDerived: \(unlisted.sorted())"))
    }

    // Every field, clock ones included, rows in the same order the oracle uses.
    private static func unexcluded(_ container: ModelContainer) throws -> [LandingOracle.Row] {
        let fresh = ModelContext(container)
        func rows<M: ScopeObserved>(_ type: M.Type) throws -> [LandingOracle.Row] {
            let named = M.scopeFields.map { (name: ScoutReLandWritesNothingTests.fieldName($0.keyPath), keyPath: $0.keyPath) }
                .sorted { $0.name < $1.name }
            return try fresh.fetch(FetchDescriptor<M>()).map { model in
                LandingOracle.Row(entity: String(describing: M.self), fields: named.map {
                    LandingOracle.Field(name: $0.name, value: LandingOracle.render(model[keyPath: $0.keyPath]))
                })
            }
        }
        var out: [LandingOracle.Row] = []
        for type in AppSchema.models {
            guard let observed = type as? any ScopeObserved.Type else { continue }
            out += try rows(observed)
        }
        // Ordered by what the clock cannot touch, so the two landings' rows line up.
        func stable(_ r: LandingOracle.Row) -> String {
            r.fields.filter { LandingOracle.clockDerived["\(r.entity).\($0.name)"] == nil }
                .map { "\($0.name)=\($0.value)" }.joined(separator: "\u{1F}")
        }
        return out.sorted { ($0.entity, $0.identity, stable($0)) < ($1.entity, $1.identity, stable($1)) }
    }

    // MARK: a real-arm mismatch never prints a value (L445)

    @Test func aRealArmMismatchNamesNoTitleVenueOrPresenter() async throws {
        let recorded = try LandingOracle.snapshot(of: await LandingOracleCorpus.land())
        let swapped = try LandingOracle.snapshot(of: await LandingOracleCorpus.land(order: Self.fenwickSwapped))
        // The expected side as the real arm stores it: hashes only.
        let expected = LandingOracle.parse(LandingOracle.realArmFile(recorded, header: []))
        let real = LandingOracle.differences(expected: expected, actual: swapped, arm: .real, limit: 10_000)
            .joined(separator: "\n")
        #expect(!real.isEmpty, Comment(rawValue: "the forced mismatch produced no differences, so this measured nothing"))
        #expect(real.contains(" field ") && real.contains("sha256:"),
                Comment(rawValue: "a real-arm difference does not name a field and two hashes: \(real.prefix(300))"))

        let names = Set(LandingOracleCorpus.stored.flatMap { [$0.title, $0.venue, $0.presenter] }
            + LandingOracleCorpus.sources.flatMap { s in
                [s.org] + s.events.flatMap { [$0.title, $0.venue ?? "", $0.presenter ?? ""] }
            }).filter { !$0.isEmpty }
        let leaked = names.filter { real.contains($0) }
        #expect(leaked.isEmpty, Comment(rawValue: "a real-arm mismatch printed \(leaked.count) titles, venues or "
                                        + "presenters"))

        // The positive control: the SAME mismatch in the synthetic arm does print values, so the silence above
        // is the real arm's redaction and not an absence of anything to print (L159).
        let synthetic = LandingOracle.differences(expected: LandingOracle.recording(of: recorded), actual: swapped,
                                                  arm: .synthetic, limit: 10_000).joined(separator: "\n")
        #expect(names.contains { synthetic.contains($0) }, Comment(rawValue:
            "the synthetic arm printed no corpus value either, so the redaction above is unmeasured"))
    }

    // MARK: the row form reads back what it wrote

    // A recording is one line per row under a `fields` line, each cell `=` then the escaped value or `h` then
    // a hash. The parser tells the two apart by that first character only, so a VALUE that itself begins with
    // "h", or holds a tab, a newline or a backslash, must come back as itself and never be read as a hash or
    // split into two cells. Also that a hashed file compares EQUAL to the values it was made from, which is
    // what lets the real arm (hashes) and the synthetic arm (values) share one comparison.
    @Test func theRowFormReadsBackEveryValueItWrote() {
        let awkward = ["h0123456789abcdef", "tab\there", "line\nbreak", "back\\slash", "", "nil", "=lead"]
        let snapshot = LandingOracle.Snapshot(rows: awkward.enumerated().map { i, v in
            LandingOracle.Row(entity: "Prospect", fields: [LandingOracle.Field(name: "groupName", value: v),
                                                           LandingOracle.Field(name: "naturalKey", value: "k\(i)")])
        })
        let values = LandingOracle.parse(LandingOracle.syntheticFile(snapshot, header: []))
        let readBack = (values.values["Prospect"] ?? []).map { $0["groupName"] ?? "absent" }
        #expect(readBack == awkward, Comment(rawValue: "the row form did not read back what it wrote: \(readBack)"))
        #expect(LandingOracle.differences(expected: values, actual: snapshot, arm: .synthetic).isEmpty)
        let hashed = LandingOracle.parse(LandingOracle.realArmFile(snapshot, header: []))
        #expect(hashed.values.isEmpty, Comment(rawValue: "a hashed recording carried values"))
        #expect(LandingOracle.differences(expected: hashed, actual: snapshot, arm: .real).isEmpty,
                Comment(rawValue: "a hashed recording does not compare equal to the values it was made from"))
    }

    // An empty list of strings is an empty list, and a list of related rows is a count: the cast from `Any` to a
    // list of models succeeds for EVERY empty array, so only a non-empty one may be read as related rows.
    @Test func anEmptyListRendersAsAListAndRelatedRowsAsACount() throws {
        #expect(LandingOracle.render([String]()) == "[]")
        #expect(LandingOracle.render(["a"]) == "[\"a\"]")
        #expect(LandingOracle.render([Recipient]()) == "[]")
        let one = Recipient(id: "oracle-render", email: "render@example.invalid", provenance: .manual)
        #expect(LandingOracle.render([one]) == "1 related")
    }

    // MARK: where a real-arm file may go, and what it starts with

    @Test func aRealArmFileIsRefusedInsideAGitWorkTreeAndWhenGitCannotAnswer() throws {
        let outside = try sandboxes.make(named: "landing-oracle-outside")
        #expect(LandingOracle.refusalToWrite(into: outside) == nil, Comment(rawValue:
            "a directory under the temp folder, outside every checkout, was refused: "
            + (LandingOracle.refusalToWrite(into: outside) ?? "")))

        let repo = try sandboxes.make(named: "landing-oracle-repo")
        let initGit = Process()
        initGit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initGit.arguments = ["-C", repo.path, "init", "-q"]
        try initGit.run()
        initGit.waitUntilExit()
        let inside = repo.appendingPathComponent("not-yet/made")
        let refusal = LandingOracle.refusalToWrite(into: inside) ?? ""
        #expect(refusal.contains("inside a git work tree"), Comment(rawValue:
            "a directory inside a git work tree was not refused: \(refusal)"))

        let noGit = LandingOracle.refusalToWrite(into: outside, git: outside.appendingPathComponent("no-git").path)
        #expect(noGit?.contains("could not run") == true, Comment(rawValue:
            "with no git to ask, the write was allowed rather than refused"))

        // A git that runs and fails for any other reason than "not a repository" is a question it did not
        // answer, and refuses too. `/usr/bin/false` stands in for it: it runs, prints nothing, exits 1.
        let failing = LandingOracle.refusalToWrite(into: outside, git: "/usr/bin/false")
        #expect(failing?.contains("did not say") == true, Comment(rawValue:
            "a git that failed without saying the directory is outside every repository was taken as a yes"))

        // Inside a .git directory git answers "false", which is still inside a repository.
        let gitDir = LandingOracle.refusalToWrite(into: repo.appendingPathComponent(".git"))
        #expect(gitDir != nil, Comment(rawValue: "a directory inside a .git directory was not refused"))
    }

    @Test func aRealArmFileBeginsWithTheMarkerThePushGuardRefuses() throws {
        let snapshot = LandingOracle.Snapshot(rows: [
            LandingOracle.Row(entity: "Prospect", fields: [LandingOracle.Field(name: "groupName", value: "x")]),
        ])
        let first = LandingOracle.realArmFile(snapshot, header: ["h"]).split(separator: "\n").first.map(String.init)
        #expect(first == LandingOracle.realArmMarker)

        // The shell guard builds the marker independently; the two must agree, or the push path refuses a
        // line nothing writes (L70).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let guardScript = RepoRoot.url.appendingPathComponent("scripts/lib/real-arm-guard.sh").path
        process.arguments = ["-c", "source \"$1\" && real_arm_marker", "bash", guardScript]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let shell = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .newlines)
        #expect(shell == LandingOracle.realArmMarker, Comment(rawValue:
            "the push guard's marker (\(shell ?? "nothing")) is not the one real-arm files begin with"))
    }

    // MARK: the real arm, opt in, on the frozen inputs

    private struct Frozen {
        let archive: URL
        let manifest: LandingOracle.Manifest
        let out: URL
        let mode: String
    }

    // Nil, having said why, when the real arm cannot or must not run.
    private func frozen() -> Frozen? {
        guard Self.env["MEASURE_4275"] != nil else {
            print("landing-oracle: real arm not measured. Set TEST_RUNNER_MEASURE_4275=1 to run it.")
            return nil
        }
        guard let inputs = Self.env["MEASURE_4275_INPUTS"], let outPath = Self.env["MEASURE_4275_OUT"] else {
            Issue.record("UNMEASURED: TEST_RUNNER_MEASURE_4275_INPUTS and TEST_RUNNER_MEASURE_4275_OUT must both name directories")
            return nil
        }
        let out = URL(fileURLWithPath: outPath)
        if let refusal = LandingOracle.refusalToWrite(into: out) {
            Issue.record(Comment(rawValue: refusal))
            return nil
        }
        let archive = URL(fileURLWithPath: inputs)
        guard let manifest = LandingOracle.manifest(at: archive.appendingPathComponent("MANIFEST")) else {
            Issue.record("UNMEASURED: the frozen inputs carry no readable MANIFEST")
            return nil
        }
        if let refusal = LandingOracle.inputsRefusal(archive: archive, manifest: manifest) {
            Issue.record(Comment(rawValue: refusal))
            return nil
        }
        let mode = Self.env["LANDING_ORACLE_MODE"] ?? "compare"
        guard mode == "record" || mode == "compare" else {
            Issue.record(Comment(rawValue: "LANDING_ORACLE_MODE must be record or compare, not \(mode)"))
            return nil
        }
        return Frozen(archive: archive, manifest: manifest, out: out, mode: mode)
    }

    // What a landing reads besides the store, which an archive must hold for the real arm to run on it.
    static let requiredInputs = ["overture-scout-extract-results.json", "downbeat-export.json", "overture-history.json"]

    @Test func realArmAt1x() async throws { try await realArm(size: "x1") }
    @Test func realArmAt4x() async throws { try await realArm(size: "x4") }

    private func realArm(size: String) async throws {
        guard let frozen = frozen() else { return }
        // Measured 2026-09-30: two processes landing the SAME frozen inputs through the SAME app code (6d3453d8
        // recording, this branch comparing) disagreed on a handful of rows at 1x and at 4x, a window of rows
        // shifting by one position, which is a Set or Dictionary order leaking into a decision (L1002, the
        // plan's 0.5 hypothesis (b)). So the real arm is recorded AND compared with Swift's hash seed fixed,
        // and refuses to run without it rather than reporting that drift as a regression. The synthetic arm
        // has matched across every process so far and runs without it.
        guard Self.env["SWIFT_DETERMINISTIC_HASHING"] == "1" else {
            Issue.record("UNMEASURED: the real arm needs TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1, because the landing is not the same across processes without it")
            return
        }
        guard let today = frozen.manifest.facts["today"], let nowText = frozen.manifest.facts["now"],
              let now = ISO8601DateFormatter().date(from: nowText) else {
            Issue.record("UNMEASURED: the MANIFEST does not pin today and now")
            return
        }
        // Every run copies the archive afresh; the archive itself is never opened (L487).
        let work = try sandboxes.make(named: "landing-oracle-\(size)")
        let storeNames = frozen.manifest.sha256.keys.filter { $0.hasPrefix(size + "/") }.sorted()
        guard let storeName = storeNames.first(where: { $0.hasSuffix(".store") }) else {
            Issue.record(Comment(rawValue: "UNMEASURED: the MANIFEST names no \(size) store"))
            return
        }
        // Every input the landing reads must be one the archive froze and hashed. One it lacks is an archive
        // this run cannot measure on, said as such rather than as a copy error (L11).
        for name in Self.requiredInputs where frozen.manifest.sha256[name] == nil {
            Issue.record(Comment(rawValue: "UNMEASURED: inputs differ from the oracle's (\(name): not in the archive)"))
            return
        }
        for name in storeNames + Self.requiredInputs {
            let to = work.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: frozen.archive.appendingPathComponent(name), to: to)
            // The archive is read only, and a copy keeps its permissions; the COPY is what the landing writes.
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: to.path)
        }
        let data = try Data(contentsOf: work.appendingPathComponent("overture-scout-extract-results.json"))
        let results = try ScoutExtractResultsDecoder.decode(data)
        let container = try Phase0.openContainer(at: work.appendingPathComponent(storeName))
        let context = container.mainContext
        context.autosaveEnabled = false
        let existing = try context.fetch(FetchDescriptor<Prospect>())
        let loaded = DownbeatBridge.loadWithHealth(from: work.appendingPathComponent("downbeat-export.json"), now: now)
        let history = LocalHistory.forMatching(existing: existing,
                                               importedFrom: work.appendingPathComponent("overture-history.json"))
        let blocked = ScoutService.blockedCalendar(export: (loaded.bookings, loaded.blockedDates, loaded.health),
                                                   context: context)
        let before = existing.count
        let outcome = await ScoutExtractIngest.ingest(results, clients: loaded.clients, history: history,
                                                      blocked: blocked, today: today, now: now, into: context)
        try context.save()
        let snapshot = try LandingOracle.snapshot(of: container)
        let events = results.results.reduce(0) { $0 + $1.events.count }
        let counts = snapshot.counts.keys.sorted().map { "\($0) \(snapshot.counts[$0] ?? 0)" }.joined(separator: ", ")
        let summary = "\(size): \(before) shows before, \(events) events over \(results.results.count) sources, "
            + "inserted \(outcome.inserted) updated \(outcome.updated) skipped \(outcome.skipped); rows after: "
            + counts + "; digest " + LandingOracle.digest(of: snapshot)
        let file = frozen.out.appendingPathComponent("real-arm-\(size).oracle")
        if frozen.mode == "record" {
            try FileManager.default.createDirectory(at: frozen.out, withIntermediateDirectories: true)
            try LandingOracle.realArmFile(snapshot, header: [
                "#4328 real arm, recorded from the frozen inputs. REAL DATA HASHED: never commit, never post.",
                "inputs today \(today) now \(nowText); Swift hash seed fixed (SWIFT_DETERMINISTIC_HASHING=1)",
            ]).write(to: file, atomically: true, encoding: .utf8)
            print("landing-oracle: RECORDED real arm " + summary)
            return
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            Issue.record(Comment(rawValue: "UNMEASURED: no recorded real arm at \(file.path)"))
            return
        }
        let differences = LandingOracle.differences(expected: LandingOracle.parse(text), actual: snapshot, arm: .real)
        print("landing-oracle: COMPARED real arm " + summary + "; \(differences.isEmpty ? "EQUAL" : "DIFFERENT")")
        #expect(differences.isEmpty, Comment(rawValue:
            "the real arm no longer leaves what 6d3453d8 left (hashes only):\n" + differences.joined(separator: "\n")))
    }

    // MARK: freezing the inputs (#4327 step 0.0), opt in

    @Test func freezeTheInputs() async throws {
        guard let target = Self.env["FREEZE_4275_TO"] else {
            print("landing-oracle: inputs not frozen. Set TEST_RUNNER_FREEZE_4275_TO=<dir> to freeze them.")
            return
        }
        let archive = URL(fileURLWithPath: target)
        if let refusal = LandingOracle.refusalToWrite(into: archive) {
            Issue.record(Comment(rawValue: refusal))
            return
        }
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: archive.path), !existing.isEmpty {
            Issue.record(Comment(rawValue: "REFUSED: \(archive.path) already holds files; an archive is written once"))
            return
        }
        let x1 = archive.appendingPathComponent("x1")
        let x4 = archive.appendingPathComponent("x4")
        try FileManager.default.createDirectory(at: x1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: x4, withIntermediateDirectories: true)
        guard let base = try LiveStoreClone.makeClone(in: x1) else {
            Issue.record("UNMEASURED: no live store on this machine")
            return
        }
        // Built from a scratch copy, so the 1x file in the archive is exactly the clone and nothing opened it.
        let scratch = try sandboxes.make(named: "landing-oracle-freeze")
        let scratchBase = scratch.appendingPathComponent("Overture.store")
        try FileManager.default.copyItem(at: base, to: scratchBase)
        let scaled = try Phase0.scaledCopy(of: scratchBase, factor: 4, in: scratch)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: scaled.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: x4.appendingPathComponent(from.lastPathComponent))
            }
        }
        let handoff = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
        // The inputs a landing reads are REQUIRED: an archive without one could never be landed on, so the
        // freeze refuses rather than writing it. The shoot history is kept when present, for later phases.
        for name in Self.requiredInputs + ["overture-shoot-history.json"] {
            let from = handoff.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: archive.appendingPathComponent(name))
            } else if Self.requiredInputs.contains(name) {
                Issue.record(Comment(rawValue: "REFUSED: \(name) is not in the handoff folder, so these inputs cannot be frozen"))
                return
            }
        }
        let now = Date()
        let facts = ["today: " + QueueModel.easternToday(),
                     "now: " + ISO8601DateFormatter().string(from: now)]
        try (facts.joined(separator: "\n") + "\n").write(to: archive.appendingPathComponent("FACTS"),
                                                         atomically: true, encoding: .utf8)
        print("landing-oracle: FROZE inputs to \(archive.path)")
    }
}
