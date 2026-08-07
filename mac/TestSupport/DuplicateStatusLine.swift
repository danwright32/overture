import Foundation

// #2168: one pair of things that say the same thing on screen.
//
// Named by what Dan READS (`says` / `alsoSays`) as well as by the source tokens, because a finding that
// only names two symbols makes whoever hits it reverse-engineer the complaint. The words are what the
// guard is actually about.
struct DuplicateStatusPair {
    /// The source token that renders the status line, e.g. the call producing "Reach out now".
    let label: String
    /// The source token that renders the control saying the same thing, e.g. the Answer capsule's copy.
    let button: String
    /// The predicate deciding whether the button is on screen. The label must yield to THIS.
    let gate: String
    /// What the status line says, in Dan's words.
    let says: String
    /// What the button says, in Dan's words.
    let alsoSays: String
}

// #2168: a net under the cold read in AGENTS.md, for the one duplicate-copy shape that keeps coming
// back: a status line sitting immediately beside the control that acts on that status.
//
// It checks the PRODUCT rule, not the presence of two strings. When the button appears only under some
// condition, the label saying the same thing has to yield under that same condition. Presence alone
// would be worthless here, because the fix for every instance keeps both in the view and makes one
// conditional, so a presence check would either fail forever or have to be deleted on the first fix.
//
// A condition that is about something ELSE does not count. Without that, any label that happened to sit
// inside any `if` would read as covered, and the guard would go quietly vacuous the way #1913 and #1992
// describe.
//
// Deliberately a hand-maintained list. Nothing here understands English. A pair goes in when a person
// notices two things saying one thing, and the guard's only job is to stop that exact pair returning.
enum DuplicateStatusLine {
    static let knownPairs: [DuplicateStatusPair] = [
        // #2166, reported by Dan from a live Reached out row on 2026-08-05: the timing label printed
        // "Reach out now" directly above the Answer button, whose existence already means "now".
        DuplicateStatusPair(label: "ReachedOutQueue.timingLabel",
                            button: "ReplyPanelCopy.answer",
                            gate: "ReplyPanel.isOffered",
                            says: "Reach out now",
                            alsoSays: "Answer")
    ]

    /// Every pair that renders unconditionally beside its own control, described in the words on screen.
    static func findings(in body: String, pairs: [DuplicateStatusPair] = knownPairs) -> [String] {
        pairs.compactMap { pair in
            // Nothing to duplicate unless both are in this container. A row that offers only one of them
            // is the ordinary case and must never be flagged.
            guard body.contains(pair.label), body.contains(pair.button) else { return nil }
            guard !yields(pair, in: body) else { return nil }
            return """
            "\(pair.says)" is rendered beside the \(pair.alsoSays) control and says the same thing. \
            The label must yield when \(pair.gate) is true (#2168, #843). \
            Tokens: \(pair.label) and \(pair.button).
            """
        }
    }

    /// Whether the label only renders when the button does not, judged by the conditions enclosing it.
    private static func yields(_ pair: DuplicateStatusPair, in body: String) -> Bool {
        guard let context = context(of: pair.label, in: body, gate: pair.gate) else { return false }
        // The gate, plus any local the gate was read into. A view that evaluates its predicate once and
        // reuses it is the ordinary spelling, and a guard that only recognised the literal call would
        // punish the tidier version of the very fix it asks for. Only locals that provably came FROM
        // the gate count, so a same-named local holding something else cannot launder an unconditional
        // label into looking covered.
        let names = [pair.gate] + context.aliases
        if names.contains(where: { context.line.contains($0) }) { return true }
        return context.conditions.contains { condition in
            names.contains { condition.contains($0) }
        }
    }

    private struct Context {
        let line: String
        let conditions: [String]
        let aliases: [String]
    }

    /// The line a token appears on, and the `if` conditions enclosing it, by brace depth.
    ///
    /// A line scanner rather than a parser, which is the right size for a hand-maintained guard over a
    /// handful of known pairs. It tracks depth so a label nested several containers below its own gate
    /// is still seen as covered, which the real view needs: the row's label sits in a VStack inside an
    /// HStack inside the function body.
    private static func context(of token: String, in body: String, gate: String = "") -> Context? {
        var openIfs: [(bodyDepth: Int, condition: String)] = []
        var aliases: [String] = []
        var depth = 0
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.contains(token) {
                return Context(line: line, conditions: openIfs.map(\.condition), aliases: aliases)
            }
            // `let offered = Panel.isOffered(...)` makes `offered` stand for the gate from here on.
            if !gate.isEmpty, line.contains(gate), let name = boundName(on: line) {
                aliases.append(name)
            }
            let opens = line.filter { $0 == "{" }.count
            let closes = line.filter { $0 == "}" }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // An `if` whose body opens on this line governs everything at the next depth down.
            if trimmed.hasPrefix("if "), opens > 0 {
                openIfs.append((bodyDepth: depth + 1, condition: trimmed))
            }
            depth += opens - closes
            while let last = openIfs.last, depth < last.bodyDepth { openIfs.removeLast() }
        }
        return nil
    }

    /// The name bound by a `let x = …` line, or nil when the line is not a binding.
    private static func boundName(on line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") else { return nil }
        let afterKeyword = trimmed.dropFirst(4)
        guard let equals = afterKeyword.firstIndex(of: "=") else { return nil }
        let name = afterKeyword[..<equals].trimmingCharacters(in: .whitespaces)
        // Only a plain identifier. A tuple or pattern binding is not something this guard reasons about.
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return name
    }
}
