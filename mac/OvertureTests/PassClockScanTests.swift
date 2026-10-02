import Foundation
import Testing

// #4356 (plan v7 Phase 2, "clock defaults deleted from `make`'s call graph"): nothing the queue's render pass
// can reach takes the clock by default, or reads it for itself.
//
// WHY THE DEFAULTS WENT. A function with `now: Date = Date()` compiles when a caller forgets `now:` and then
// silently reads the wall clock, so a pass handed a pinned instant answers part of its question about a
// different one (L168). Deleting the default from every function the pass reaches turns each such call site
// into a compile error, which is the guard; this scan keeps a default from coming back, and refuses a body
// that reads the clock directly, which no compiler can see.
//
// The scope is `PassCallGraph`, derived from the code; its header says what that derivation can and cannot
// see. Reported by function and by the chain that reaches it, so a finding can be traced without rerunning.
// `PassAmbientReadScanTests` is the same scan for every other input the pass was not handed.
// `.sharesTheRenderCounter` because the allowance below names `QueueRenderCounter`, which is what
// `SharedStateWiringTests` keys on; this suite only reads source and never touches the counter.
@Suite("Nothing the render pass reaches takes or reads the clock for itself (#4356)", .sharesTheRenderCounter)
struct PassClockScanTests {

    static var graph: PassCallGraph.Graph { PassCallGraph.queuePass }

    /// A parameter defaulted to the current instant, or to today worked out from it.
    /// A default expression that reads the clock anywhere inside it, so `today: String =
    /// EasternDate.today(Date())` is found as surely as `now: Date = Date()`.
    static let clockDefault = try! NSRegularExpression(pattern: #"""
        \w+\s*:\s*[^=,\n]+?=\s*[^,\n]*?(?:\bDate\(\)|\bDate\.now\b|[=(\s]\.now\b
        | (?:QueueModel\.easternToday|EasternDate\.today)\(\s*\))
        """#, options: [.allowCommentsAndWhitespace])

    /// A read of the wall clock, or of the day worked out from it.
    static let clockRead = try! NSRegularExpression(pattern: #"""
        \bDate\(\) | \bDate\.now\b | [=(,:\[]\s*\.now\b | \bDate\(timeIntervalSinceNow | \bDispatchTime\.now
        | \bContinuousClock\.now | \bCFAbsoluteTimeGetCurrent
        | (?:QueueModel\.easternToday|EasternDate\.today)\(\s*\)
        """#, options: [.allowCommentsAndWhitespace])

    /// Clock reads the pass makes on purpose, each with the reason and the change that removes it.
    static let allowedClockReads: [String: String] = [
        "QueueRenderCounter.append": """
            The Debug derivation counter `make` calls inside `#if DEBUG`, which stamps each line it logs. Plan \
            v7 Phase 3 (#4357) moves every side effect out of `make` and takes this with it.
            """,
    ]

    static func matches(_ pattern: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    // The positive control for both scans below: a graph that lost its parser would reach nothing and
    // pass them both (L98). These are calls `make` is known to make, at every depth.
    @Test func theGraphReachesWhatThePassIsKnownToCall() {
        for (type, name) in [("QueueModel", "scope"), ("QueueModel", "card"), ("StageNavigation", "placements"),
                             ("AgentInputs", "from"), ("ShowLink", "group"), ("ProducerGate", "key"),
                             ("ReachedOutQueue", "activeWithDates"), ("OrgAnswerLedger", "inherited"),
                             ("DueWork", "counts"), ("EasternDate", "today")] {
            #expect(Self.graph.contains(type: type, name: name),
                    Comment(rawValue: "the pass's call graph does not reach \(type).\(name), so it is too small "
                        + "to trust; reached \(Self.graph.reached.count) of \(Self.graph.declarations.count)"))
        }
        // And it is not the whole app either, which is what a resolver that followed every name would give.
        #expect(Self.graph.reached.count < Self.graph.declarations.count / 3,
                "the graph reached most of the app, so it no longer separates the pass from anything else")
    }

    @Test func noFunctionThePassReachesTakesTheClockByDefault() {
        var found: [String] = []
        for d in Self.graph.reached {
            for hit in Self.matches(Self.clockDefault, in: d.header) {
                found.append("\(d.file):\(d.line) \(d.type).\(d.name) defaults `\(hit)`, reached by "
                             + Self.graph.path(to: d))
            }
        }
        #expect(found.isEmpty, Comment(rawValue: "a caller inside the render pass that forgets `now:` compiles "
            + "and reads the wall clock. Delete the default and pass the pass's own instant:\n"
            + found.joined(separator: "\n")))
    }

    @Test func noFunctionThePassReachesReadsTheClock() {
        var found: [String] = []
        for d in Self.graph.reached where Self.allowedClockReads["\(d.type).\(d.name)"] == nil {
            for hit in Self.matches(Self.clockRead, in: d.body) {
                found.append("\(d.file):\(d.line) \(d.type).\(d.name) reads `\(hit)`, reached by "
                             + Self.graph.path(to: d))
            }
        }
        #expect(found.isEmpty, Comment(rawValue: "the render pass reads the clock for itself, so a pinned "
            + "instant is not the instant it reasons in. Read the pass's own `now`:\n"
            + found.joined(separator: "\n")))
    }

    // An allowance that no longer matches a reached function exempts nothing today and would exempt a
    // future one that takes the name (L362).
    @Test func everyAllowanceIsStillReachedAndStillReads() {
        for (key, reason) in Self.allowedClockReads {
            let reached = Self.graph.reached.filter { "\($0.type).\($0.name)" == key }
            #expect(reached.contains { !Self.matches(Self.clockRead, in: $0.body).isEmpty },
                    Comment(rawValue: "\(key) is allowed a clock read and no longer makes one inside the pass; "
                        + "delete the allowance"))
            #expect(reason.first?.isLetter == true, Comment(rawValue: "\(key) is allowed with no written reason"))
        }
    }
}

// #4356 (plan v7 Phase 2): nothing the queue's render pass can reach reads state it was not handed.
//
// The engine (Phase 4) runs this pass only when one of its inputs changed: a row, a small table, the clock's
// recorded deadline, or a context source's signal (`QueueInputSource`). A file, a user default, a shared
// singleton or a mutable static read from INSIDE the pass changes with none of those noticing, so the screen
// would keep an old answer until something unrelated ran a pass. Every such read has to enter through
// `QueueRenderPass.Inputs`, where `QueueInputSourceTests` makes it name its source (plan v5 D4).
//
// The scope is the same derived graph `PassClockScanTests` reads (`PassCallGraph.queuePass`). A mutable
// static is found from its declaration anywhere in the app and then looked for, qualified by its type, in
// every reached body.
@Suite("Nothing the render pass reaches reads ambient state for itself (#4356)")
struct PassAmbientReadScanTests {

    static let ambientRead = try! NSRegularExpression(pattern: #"""
        \bUserDefaults\b | \bFileManager\b | \bProcessInfo\b | \bBundle\.main\b | \bCalendar\.current\b
        | \bTimeZone\.current\b | \bLocale\.current\b | \bNSApp\b | \bNSWorkspace\b | \.shared\b
        """#, options: [.allowCommentsAndWhitespace])

    /// `Type.name` for every `static var` the app declares with storage, which is the mutable shared state
    /// a function can read without being handed it. A `@TaskLocal` is excluded by its own nature: it is bound
    /// by the caller for the duration of a call, which is a parameter in all but spelling.
    static func mutableStatics() -> Set<String> {
        var found: Set<String> = []
        for file in AppSourceWalk.appFiles() {
            let lines = SwiftSource.scannableLines(in: file.text).map(\.code)
            var owner: String?
            for line in lines {
                if let type = typeDeclared(on: line) { owner = type }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let owner, trimmed.contains("static var "), !trimmed.contains("@TaskLocal"),
                      !trimmed.hasSuffix("{") else { continue }
                let afterVar = trimmed.components(separatedBy: "static var ").last ?? ""
                if let name = afterVar.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).first {
                    found.insert("\(owner).\(name)")
                }
            }
        }
        return found
    }

    static func typeDeclared(on line: String) -> String? {
        let words = line.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
        for (index, word) in words.enumerated()
        where ["struct", "enum", "class", "extension", "actor"].contains(word) && index + 1 < words.count {
            return words[index + 1]
        }
        return nil
    }

    /// Reads the pass makes on purpose, each with the reason and the change that removes it.
    static let allowed: [String: String] = [:]

    @Test func noFunctionThePassReachesReadsAmbientState() {
        let graph = PassCallGraph.queuePass
        #expect(graph.contains(type: "QueueModel", name: "scope"),
                "the pass's graph does not reach QueueModel.scope, so this scan covers nothing")
        let statics = Self.mutableStatics()
        #expect(!statics.isEmpty, "no mutable static was found anywhere in the app, so that half checked nothing")
        var found: [String] = []
        for d in graph.reached where Self.allowed["\(d.type).\(d.name)"] == nil {
            let range = NSRange(d.body.startIndex..., in: d.body)
            for match in Self.ambientRead.matches(in: d.body, range: range) {
                let hit = Range(match.range, in: d.body).map { String(d.body[$0]) } ?? "?"
                found.append("\(d.file):\(d.line) \(d.type).\(d.name) reads `\(hit)`, reached by \(graph.path(to: d))")
            }
            for name in statics where d.body.contains(name) {
                found.append("\(d.file):\(d.line) \(d.type).\(d.name) reads the mutable static `\(name)`, "
                             + "reached by \(graph.path(to: d))")
            }
        }
        #expect(found.isEmpty, Comment(rawValue: "the render pass reads state it was not handed, so a change to "
            + "it reaches no engine signal. Hand it in through QueueRenderPass.Inputs:\n"
            + found.joined(separator: "\n")))
    }
}
