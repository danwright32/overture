import Testing
import Foundation
import SwiftData

// #4357 slice E1: the class fix for a recursion that crash looped the suite.
//
// Slice D1 left seven typed views on the models whose getters read the facts protocol's one body through an
// opaque view of the model (`Prospect.asProspectFacts`, `Recipient.asContactFacts`): `status`, `showOutcome` and
// `outcome` on the show, `sendState`, `resolution`, `outcomeSource` and `outreachChannel` on the contact. That
// is safe exactly while the facts protocol does NOT require the member: the read through the view then reaches
// the extension's body statically. The moment any protocol the facts protocol refines requires it, the read is
// dispatched to the model's own witness, which is the getter doing the reading, and it recurses until the stack
// runs out. A first cut of slice E1 did exactly that (`ProspectFacts` refining `PrepEligibilityFacts`, which
// requires `status`): 261 test host crashes in one run, `Thread stack size exceeded`.
//
// TWO HALVES. The runtime half reads every view, on a real model, through every protocol that declares it and
// through the facts protocol's extension; a recursion there crashes this one suite rather than the whole run,
// so a scoped run of it is where a refinement that recurses is caught. The source half DERIVES the pairs from
// the code, the protocols each model conforms to (and everything they refine) crossed with the views each
// declares, and fails on a pair the runtime half does not read, so a new conformance or a new requirement
// cannot arrive unread (L96).
@MainActor
@Suite("Every typed view answers through every protocol its model conforms to (#4357)")
struct TypedViewsAnswerThroughEveryConformanceTests {
    static let showViews = ["status", "showOutcome", "outcome"]
    static let contactViews = ["sendState", "resolution", "outcomeSource", "outreachChannel"]

    // MARK: the readers, one per protocol and view

    private static func factsStatus<T: ProspectFacts>(_ t: T) -> String { "\(t.status)" }
    private static func factsShowOutcome<T: ProspectFacts>(_ t: T) -> String { String(describing: t.showOutcome) }
    private static func factsOutcome<T: ProspectFacts>(_ t: T) -> String { "\(t.outcome)" }
    private static func prepStatus<T: PrepEligibilityFacts>(_ t: T) -> String { "\(t.status)" }
    private static func contactSendState<T: ContactFacts>(_ t: T) -> String { "\(t.sendState)" }
    private static func contactResolution<T: ContactFacts>(_ t: T) -> String { String(describing: t.resolution) }
    private static func contactOutcomeSource<T: ContactFacts>(_ t: T) -> String { String(describing: t.outcomeSource) }
    private static func contactChannel<T: ContactFacts>(_ t: T) -> String { "\(t.outreachChannel)" }

    /// "Protocol.view" to the read through that protocol. The facts protocols' entries read the extension body.
    static let showReaders: [String: (Prospect) -> String] = [
        "ProspectFacts.status": { factsStatus($0) },
        "ProspectFacts.showOutcome": { factsShowOutcome($0) },
        "ProspectFacts.outcome": { factsOutcome($0) },
        "PrepEligibilityFacts.status": { prepStatus($0) },
    ]

    static let contactReaders: [String: (Recipient) -> String] = [
        "ContactFacts.sendState": { contactSendState($0) },
        "ContactFacts.resolution": { contactResolution($0) },
        "ContactFacts.outcomeSource": { contactOutcomeSource($0) },
        "ContactFacts.outreachChannel": { contactChannel($0) },
    ]

    private static func model(_ p: Prospect, _ view: String) -> String {
        switch view {
        case "status": return "\(p.status)"
        case "showOutcome": return String(describing: p.showOutcome)
        default: return "\(p.outcome)"
        }
    }

    private static func model(_ r: Recipient, _ view: String) -> String {
        switch view {
        case "sendState": return "\(r.sendState)"
        case "resolution": return String(describing: r.resolution)
        case "outcomeSource": return String(describing: r.outcomeSource)
        default: return "\(r.outreachChannel)"
        }
    }

    // MARK: the runtime half

    @Test func everyViewReadThroughEveryProtocolReturnsWhatTheModelSays() throws {
        let ctx = ModelContext(try TestModelContainer.inMemory([Prospect.self, Recipient.self]))
        let p = Prospect(naturalKey: "views", groupName: "Typed Views", discipline: "music", venue: "Quillon Room",
                         performanceDate: "2026-10-20", sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3, tier: "medium",
                         fitReason: "", matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.statusRaw = ReviewStatus.contacted.rawValue
        p.showOutcomeRaw = ShowOutcome.allCases.first?.rawValue
        p.outcomeRaw = Outcome.booked.rawValue
        let r = Recipient(id: "views", email: "views@example.invalid", provenance: .act)
        r.sendState = .sent
        r.resolution = .booked
        r.outcomeSource = .manual
        ctx.insert(p)
        ctx.insert(r)
        p.recipients.append(r)

        for (key, read) in Self.showReaders.sorted(by: { $0.key < $1.key }) {
            let view = String(key.split(separator: ".").last ?? "")
            #expect(read(p) == Self.model(p, view), Comment(rawValue: "\(key) disagreed with the model"))
        }
        for (key, read) in Self.contactReaders.sorted(by: { $0.key < $1.key }) {
            let view = String(key.split(separator: ".").last ?? "")
            #expect(read(r) == Self.model(r, view), Comment(rawValue: "\(key) disagreed with the model"))
        }
    }

    // MARK: the source half

    /// The protocols a model conforms to, from every `extension Model: A, B` in the app, and every protocol each
    /// of those refines, followed to the end.
    static func conformances(of model: String, in files: [AppSourceWalk.File]) -> Set<String> {
        let lines = files.flatMap { SwiftSource.scannableLines(in: $0.text).map(\.code) }
        func inheritance(after prefix: String) -> [String] {
            lines.compactMap { line -> [String]? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(prefix) else { return nil }
                let rest = trimmed.dropFirst(prefix.count)
                let clause = rest.split(separator: "{").first.map(String.init) ?? String(rest)
                return clause.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.contains(" ") }
            }.flatMap { $0 }
        }
        var found = Set(inheritance(after: "extension \(model): "))
        var frontier = Array(found)
        while let next = frontier.popLast() {
            for parent in inheritance(after: "protocol \(next): ") where !found.contains(parent) {
                found.insert(parent)
                frontier.append(parent)
            }
        }
        return found
    }

    /// The views `proto` declares as requirements, read from its declaration's body.
    static func requirements(of proto: String, among views: [String], in files: [AppSourceWalk.File]) -> Set<String> {
        var out: Set<String> = []
        for file in files {
            let lines = SwiftSource.scannableLines(in: file.text).map(\.code)
            guard let start = lines.firstIndex(where: {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("protocol \(proto) {") || t.hasPrefix("protocol \(proto): ")
            }) else { continue }
            for line in lines[(start + 1)...] {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("}") { break }
                for view in views where t.hasPrefix("var \(view):") { out.insert(view) }
            }
        }
        return out
    }

    @Test func everyProtocolThatRequiresAViewIsReadAboveDerivedFromTheCode() {
        let files = AppSourceWalk.appFiles()
        var missing: [String] = []
        var asked = 0
        for (model, views, readers) in [("Prospect", Self.showViews, Set(Self.showReaders.keys)),
                                        ("Recipient", Self.contactViews, Set(Self.contactReaders.keys))] {
            let protocols = Self.conformances(of: model, in: files)
            #expect(!protocols.isEmpty, "found no conformance of \(model), so nothing was derived (L98)")
            for proto in protocols.sorted() {
                for view in Self.requirements(of: proto, among: views, in: files).sorted() {
                    asked += 1
                    if !readers.contains("\(proto).\(view)") { missing.append("\(model) through \(proto).\(view)") }
                }
            }
        }
        // Positive control (L159): today `PrepEligibilityFacts` requires `status` and `Prospect` conforms to it.
        #expect(asked > 0, "the scan found no protocol requiring a view, so it measured nothing")
        #expect(missing.isEmpty, Comment(rawValue: "these reads are required by a conformance and not read above, "
                                         + "so a recursion through them would go unseen: \(missing.joined(separator: ", "))"))
    }
}
