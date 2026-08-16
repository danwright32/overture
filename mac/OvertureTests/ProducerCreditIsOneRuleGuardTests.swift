import Testing
import Foundation

// #2452: a standing guard that "does this credit line name a producing company?" is answered in ONE
// place, by every reader that has to answer it.
//
// SupertitleIsOneProducerRuleTests pins the answers themselves, adapter against adapter. What no
// behavioural test can catch is a FIFTH reader arriving next year with a rule of its own: the defect is
// not in any one answer, it is in there being two, and a new adapter's own reading is green from the day
// it ships (L89). Three of the four readers here had drifted apart exactly that way before this shipped,
// and each file read as correct alone, which is why nothing noticed.
//
// Two independent routes meet here, deliberately (L70). What the shared rule OFFERS is parsed from
// ProducerShapedName.swift; which readers have to ask it is written from what the product does, and the
// list of readers is then checked against a sweep DERIVED from the code, so an adapter nobody added to
// the list fails rather than being silently exempt from the check meant to catch it (L96).
enum ProducerCreditAudit {

    // A reader that decides who presents a row, and the function where it decides.
    struct Site: Equatable, Sendable {
        let path: String        // relative to mac/
        let function: String    // the declaration whose body must reach the shared rule
        let decides: String     // what it decides, in the words a failure should use
    }

    // A file that builds an ExtractedEvent presenter WITHOUT asking the rule, and the reason it does not
    // have to. Each reason is a claim about that feed, not an allowlist entry: a feed naming its
    // organisation in a field of its own has no credit line to read, so there is nothing to route.
    struct Exempt: Equatable, Sendable {
        let path: String
        let why: String
    }

    enum Finding: Equatable, CustomStringConvertible {
        case nothingToInspect(what: String)
        case fileUnreadable(path: String)
        case functionMissing(path: String, function: String)
        case doesNotAskTheSharedRule(decides: String, path: String)
        case privateCopy(path: String, tell: String)
        case unknownPresenterWriter(path: String)

        var description: String {
            switch self {
            case let .nothingToInspect(what):
                return "the guard found no \(what) at all, so it was protecting nothing (#2452)"
            case let .fileUnreadable(path):
                return "\(path) could not be read: a producer-credit reader moved and this guard went blind"
            case let .functionMissing(path, function):
                return "\(path) no longer declares \(function), so that reader is no longer being checked"
            case let .doesNotAskTheSharedRule(decides, path):
                return "\(decides) (\(path)) no longer calls ProducerShapedName, so it is deciding on its own"
            case let .privateCopy(path, tell):
                return "\(path) names \(tell), an ingredient of the producer-name rule, so the rule has a "
                     + "second home outside ProducerShapedName.swift"
            case let .unknownPresenterWriter(path):
                return "\(path) builds an ExtractedEvent presenter and is neither routed through "
                     + "ProducerShapedName nor recorded as a feed with no credit line to read"
            }
        }
    }

    // The ingredients of the rule. Naming any of them outside its own file means somebody is rebuilding
    // it rather than calling it. Each is spelled the way it appears in code (a quoted word, or a
    // declaration name), so the classifier regex in EventClassifier, which lists similar WORDS for an
    // unrelated question, is not mistaken for a copy of this rule.
    static let ingredientTells = ["\"productions\"", "\"entertainment\"", "\"collective\"",
                                  "\"hosted by \"", "withoutPossessive"]

    // The source as a guard has to read it: comments gone, so prose describing the rule (this file's
    // subjects are full of it) is never mistaken for code that implements it. String contents stay,
    // because a re-listed organisation word is a string literal.
    static func code(in source: String, skipping: SwiftSource.Skips = []) -> String {
        SwiftSource.scannableLines(in: source, skipping: skipping).map(\.code).joined(separator: "\n")
    }

    // Route one: what the shared rule actually offers, read from its own declaration rather than from a
    // list written beside it. Renaming an entry point fails loudly here instead of quietly shrinking
    // what the rest of this suite asserts.
    static func entryPoints(inProducerShapedName source: String) -> [String] {
        var names: Set<String> = []
        for line in SwiftSource.scannableLines(in: source, skipping: []) {
            guard let range = line.code.range(of: "static func ") else { continue }
            let name = line.code[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { names.insert(String(name)) }
        }
        return names.sorted()
    }

    // Route two: every reader on the inventory reaches the rule from inside the function that decides.
    static func audit(sites: [Site], read: (String) -> String?) -> [Finding] {
        var findings: [Finding] = []
        if sites.isEmpty { findings.append(.nothingToInspect(what: "producer-credit readers")) }
        for site in sites {
            guard let source = read(site.path), !source.isEmpty else {
                findings.append(.fileUnreadable(path: site.path))
                continue
            }
            guard let body = try? SourceGuard.functionBody(named: site.function, in: code(in: source)) else {
                findings.append(.functionMissing(path: site.path, function: site.function))
                continue
            }
            if !body.contains("ProducerShapedName.") {
                findings.append(.doesNotAskTheSharedRule(decides: site.decides, path: site.path))
            }
        }
        return findings
    }

    // The rule has one home. A marked copy-inventory region buys no exemption here: a marking says "this
    // is not Dan's copy", never "this may be reimplemented wherever you like".
    static func privateCopies(files: [(path: String, source: String)], homePath: String,
                              tells: [String]) -> [Finding] {
        var findings: [Finding] = []
        if files.isEmpty { findings.append(.nothingToInspect(what: "app source files")) }
        if tells.isEmpty { findings.append(.nothingToInspect(what: "producer-rule ingredients")) }
        for file in files where file.path != homePath {
            let text = code(in: file.source)
            for tell in tells where text.contains(tell) {
                findings.append(.privateCopy(path: file.path, tell: tell))
            }
        }
        return findings
    }

    // Route three, derived from the code rather than remembered: every app file that builds an
    // ExtractedEvent with a presenter. An adapter added next year appears here on the day it is written,
    // and has to be either routed or given a stated reason. A registry checked only against itself can
    // never report the entry nobody made (L96).
    static func presenterWriters(files: [(path: String, source: String)]) -> [String] {
        files.filter { file in
            let text = code(in: file.source)
            return text.contains("ExtractedEvent(") && text.contains("presenter:")
        }.map(\.path).sorted()
    }

    static func unknownPresenterWriters(files: [(path: String, source: String)],
                                        routed: Set<String>, exempt: Set<String>) -> [Finding] {
        var findings: [Finding] = []
        let writers = presenterWriters(files: files)
        if writers.isEmpty { findings.append(.nothingToInspect(what: "ExtractedEvent presenter writers")) }
        for path in writers where !routed.contains(path) && !exempt.contains(path) {
            findings.append(.unknownPresenterWriter(path: path))
        }
        return findings
    }

    // Every app Swift file keyed by its path relative to `mac/`, which is the form the inventories are
    // written in. Takes the root it walks so the derivation can be exercised against a throwaway tree.
    // The relative path goes through CopyInventory's symlink-canonicalising strip, because an agent's
    // worktree lives under a symlinked TMPDIR and a raw prefix strip yields absolute paths there, which
    // would put every file outside every inventory at once (#2361).
    static func appSources(macRoot: URL, floor: Int = AppSourceWalk.appFloor)
        -> [(path: String, source: String)] {
        AppSourceWalk.files(under: macRoot.appendingPathComponent("Overture"), floor: floor)
            .map { (path: CopyInventory.relativePath(of: $0.url, under: macRoot), source: $0.text) }
    }
}

@Suite("One producer-name rule, asked by every reader (#2452)")
struct ProducerCreditIsOneRuleGuardTests {

    private static let homePath = "Overture/Domain/ProducerShapedName.swift"

    // The readers. Written from what the product does, reader by reader, rather than gathered by
    // grepping for calls to the rule: a list built from the calls it checks would agree with itself by
    // construction and could never report a reader that stopped making them (L70).
    private static let sites: [ProducerCreditAudit.Site] = [
        .init(path: "Overture/Integration/VenueTixCalendar.swift", function: "extractedEvents",
              decides: "who presents a VenueTix show, from the feed's supertitle"),
        .init(path: "Overture/Integration/OvationTixCalendar.swift", function: "extractedEvents",
              decides: "who presents an OvationTix production, from the feed's supertitle"),
        .init(path: "Overture/Integration/TicketTailorCalendar.swift", function: "extractedEvents",
              decides: "who presents a TicketTailor show, from a widget that publishes no credit line"),
        .init(path: "Overture/Domain/ListingOrganiser.swift", function: "producerNamed",
              decides: "who produces a show, from the credit in front of the title on its listing page")
    ]

    // The feeds with no credit line to read. Each reason is about that feed's own shape, checked against
    // the parser beside it, and is why nothing is routed rather than a licence not to.
    private static let exempt: [ProducerCreditAudit.Exempt] = [
        .init(path: "Overture/Integration/SquarespaceCalendar.swift",
              why: "an organisation's OWN events page: it presents, and no phrase stands above the title"),
        .init(path: "Overture/Integration/OperaAmericaCalendar.swift",
              why: "the feed names the producing company in a field of its own (`company`)"),
        .init(path: "Overture/Integration/AlgoliaCalendar.swift",
              why: "the feed names the licensee in a field of its own (`licenseename`)"),
        .init(path: "Overture/Domain/RoomPresenterSweep.swift",
              why: "re-reads a presenter already STORED on a row, never a feed's credit line"),
        .init(path: "Overture/Domain/ActIsThePartyRealignment.swift",
              why: "re-reads a presenter already STORED on a row, never a feed's credit line (#2504)"),
        .init(path: "Overture/Domain/FragmentMatchCorrection.swift",
              why: "re-reads a presenter already STORED on a row, never a feed's credit line (#2565)"),
        .init(path: "Overture/Domain/ScoutExtractResults.swift",
              why: "the paid AI-read boundary: the run reports the presenter it read off the page")
    ]

    private static func read(_ relativeToMac: String) -> String? {
        try? String(contentsOf: RepoRoot.mac.appendingPathComponent(relativeToMac), encoding: .utf8)
    }

    private static func appSources() -> [(path: String, source: String)] {
        ProducerCreditAudit.appSources(macRoot: RepoRoot.mac)
    }

    // MARK: - The rule the readers are held to

    @Test func theSharedRuleStillDeclaresTheEntryPointsTheReadersUse() throws {
        let source = try #require(Self.read(Self.homePath))
        let entryPoints = ProducerCreditAudit.entryPoints(inProducerShapedName: source)

        #expect(!entryPoints.isEmpty, "ProducerShapedName.swift parsed to no entry points at all")
        #expect(entryPoints.contains("from"), "ProducerShapedName no longer declares from")
        #expect(entryPoints.contains("presenter"),
                "ProducerShapedName no longer declares presenter, which every feed adapter calls")
    }

    // MARK: - The invariant itself

    @Test func everyReaderDecidesThroughTheSharedRule() {
        let findings = ProducerCreditAudit.audit(sites: Self.sites, read: Self.read)
        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    @Test func theRuleHasNoSecondHome() {
        let findings = ProducerCreditAudit.privateCopies(
            files: Self.appSources(), homePath: Self.homePath,
            tells: ProducerCreditAudit.ingredientTells)
        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    // The fifth reader nobody told the guard about: a file that writes an ExtractedEvent presenter and
    // is on neither list.
    @Test func noUnrecordedReaderWritesAnExtractedEventPresenter() {
        let files = Self.appSources()
        let findings = ProducerCreditAudit.unknownPresenterWriters(
            files: files, routed: Set(Self.sites.map(\.path)), exempt: Set(Self.exempt.map(\.path)))

        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    // Non-vacuous: the sweep must still be FINDING the readers it knows about, or it has stopped
    // recognising the shape and would wave a real fifth one straight through (L63).
    @Test func theSweepStillRecognisesTheReadersItKnowsAbout() {
        let writers = Set(ProducerCreditAudit.presenterWriters(files: Self.appSources()))

        #expect(writers.count >= 6, "the sweep found \(writers.count) presenter writers, which is too few")
        for path in ["Overture/Integration/VenueTixCalendar.swift",
                     "Overture/Integration/OvationTixCalendar.swift",
                     "Overture/Integration/TicketTailorCalendar.swift",
                     "Overture/Integration/SquarespaceCalendar.swift"] {
            #expect(writers.contains(path), "the sweep no longer sees \(path) writing a presenter")
        }
        // ListingOrganiser answers the same question without building an event, so it is on the
        // inventory and NOT expected from the sweep. Pinned so the two routes stay distinguishable.
        #expect(!writers.contains("Overture/Domain/ListingOrganiser.swift"))
    }

    // Every exemption names a real file. A reason attached to a path that no longer exists is an
    // exemption for nothing, and the file it once covered would be reported instead of quietly passing.
    @Test func everyExemptionNamesAFileThatIsStillThere() {
        for entry in Self.exempt {
            #expect(Self.read(entry.path) != nil, "\(entry.path) is exempt (\(entry.why)) but is gone")
            #expect(!entry.why.isEmpty)
        }
    }

    // MARK: - The guard's own failure paths, seen to fail

    @Test func anEmptyInventoryFailsInsteadOfReportingACleanSweep() {
        #expect(ProducerCreditAudit.audit(sites: [], read: { _ in "" })
                == [.nothingToInspect(what: "producer-credit readers")])
    }

    @Test func aReaderWhoseFileHasMovedFails() {
        let findings = ProducerCreditAudit.audit(sites: [Self.sites[0]], read: { _ in nil })
        #expect(findings == [.fileUnreadable(path: Self.sites[0].path)])
    }

    @Test func aReaderWhoseFunctionHasBeenRenamedFails() {
        let findings = ProducerCreditAudit.audit(
            sites: [Self.sites[0]], read: { _ in "enum VenueTixCalendar { static func rows() -> Int { 0 } }" })
        #expect(findings == [.functionMissing(path: Self.sites[0].path, function: "extractedEvents")])
    }

    @Test func aReaderThatStopsAskingTheSharedRuleFails() {
        let findings = ProducerCreditAudit.audit(sites: [Self.sites[0]], read: { _ in """
            static func extractedEvents(from events: [VTEvent], presenter: String) -> [ExtractedEvent] {
                events.map { ExtractedEvent(title: $0.title, presenter: presenter) }
            }
            """ })
        #expect(findings == [.doesNotAskTheSharedRule(decides: Self.sites[0].decides,
                                                      path: Self.sites[0].path)])
    }

    // The rule named only in a COMMENT is not a second home. Every one of these files explains the rule
    // in prose, and a guard that could not tell prose from code would report those sentences forever.
    @Test func theRuleDescribedInACommentIsNotASecondHome() {
        let findings = ProducerCreditAudit.privateCopies(
            files: [(path: "Overture/Integration/OvationTixCalendar.swift",
                     source: """
                        // The rule keeps a supertitle ending in "Productions" or "Entertainment", and
                        // withoutPossessive strips the trailing apostrophe.
                        let named = ProducerShapedName.presenter(creditedAbove: e.superTitle,
                                                                 orElse: presenter)
                        """)],
            homePath: Self.homePath, tells: ProducerCreditAudit.ingredientTells)
        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    // The fixture path is EventClassifier deliberately: it really does hold a word list of its own, for
    // the unrelated question of whether a presenter looks like a producing body rather than an agency.
    // That list is a regex of bare words, so it is not a copy of this rule; a file re-listing this rule's
    // words as its own quoted tokens is.
    @Test func aRebuiltRuleInAnotherFileFails() {
        let rebuilt = "Overture/Domain/EventClassifier.swift"
        let findings = ProducerCreditAudit.privateCopies(
            files: [(path: rebuilt,
                     source: """
                        guard core.lowercased().hasSuffix("productions")
                            || core.lowercased().hasSuffix("entertainment") else { return nil }
                        """)],
            homePath: Self.homePath, tells: ProducerCreditAudit.ingredientTells)
        #expect(findings.contains(.privateCopy(path: rebuilt, tell: "\"productions\"")))
        #expect(findings.contains(.privateCopy(path: rebuilt, tell: "\"entertainment\"")))
    }

    // A copy-inventory marking exempts a region from the list of what Overture SAYS; it must not exempt
    // it from being a second copy of the rule.
    @Test func aRebuiltRuleInsideAMarkedRegionStillFails() {
        let rebuilt = "Overture/Integration/SiblingCalendar.swift"
        let findings = ProducerCreditAudit.privateCopies(
            files: [(path: rebuilt,
                     source: """
                        // copy-inventory:ignore-start  parser tokens
                        if core.lowercased().contains("collective") { return core }
                        // copy-inventory:ignore-end
                        """)],
            homePath: Self.homePath, tells: ProducerCreditAudit.ingredientTells)
        #expect(findings == [.privateCopy(path: rebuilt, tell: "\"collective\"")])
    }

    @Test func theHomeOfTheRuleIsNotReportedAsACopyOfItself() {
        let findings = ProducerCreditAudit.privateCopies(
            files: [(path: Self.homePath,
                     source: "if core.contains(\"productions\") || core.contains(\"collective\") { }")],
            homePath: Self.homePath, tells: ProducerCreditAudit.ingredientTells)
        #expect(findings.isEmpty)
    }

    @Test func aPrivateCopySweepWithNothingToWalkFails() {
        #expect(ProducerCreditAudit.privateCopies(files: [], homePath: Self.homePath,
                                                  tells: ProducerCreditAudit.ingredientTells)
                == [.nothingToInspect(what: "app source files")])
        #expect(ProducerCreditAudit.privateCopies(
            files: [(path: "a.swift", source: "let x = 1")], homePath: Self.homePath, tells: [])
                == [.nothingToInspect(what: "producer-rule ingredients")])
    }

    @Test func aNewAdapterThatWritesAPresenterIsReported() {
        let newAdapter = "Overture/Integration/SiblingCalendar.swift"
        let findings = ProducerCreditAudit.unknownPresenterWriters(
            files: [(path: newAdapter,
                     source: "ExtractedEvent(title: e.name, presenter: venueName)")],
            routed: Set(Self.sites.map(\.path)), exempt: Set(Self.exempt.map(\.path)))

        #expect(findings == [.unknownPresenterWriter(path: newAdapter)])
    }

    @Test func aSweepThatFindsNoPresenterWriterAtAllFails() {
        let findings = ProducerCreditAudit.unknownPresenterWriters(
            files: [(path: "Overture/Domain/Prospect.swift", source: "let x = 1")],
            routed: [], exempt: [])
        #expect(findings == [.nothingToInspect(what: "ExtractedEvent presenter writers")])
    }

    // A file that merely NAMES the type without building one is not a presenter writer, or the sweep
    // would demand a reason from every consumer of the event as well as every producer of it.
    @Test func aFileThatOnlyReadsExtractedEventsIsNotAPresenterWriter() {
        let writers = ProducerCreditAudit.presenterWriters(files: [
            (path: "Overture/Domain/EventClassifier.swift",
             source: "static func classify(_ event: ExtractedEvent) { let p = event.presenter }")])
        #expect(writers.isEmpty)
    }

    // Where the checkout lives cannot change the verdict: an agent's worktree sits under a symlinked
    // TMPDIR, and a path derivation that broke there would put every file outside every inventory and
    // report the whole app as unrecorded readers (#2361).
    @Test func theSweepKeysFilesTheSameWayInASymlinkedCheckout() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("producer-credit-guard-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }

        let real = base.appendingPathComponent("checkout/mac/Overture/Domain")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try "enum ProducerShapedName { static func from(_ s: String?) -> String? { nil } }"
            .write(to: real.appendingPathComponent("ProducerShapedName.swift"),
                   atomically: true, encoding: .utf8)
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("checkout"))

        let files = ProducerCreditAudit.appSources(macRoot: link.appendingPathComponent("mac"), floor: 1)
        #expect(files.map(\.path) == [Self.homePath])
    }
}
