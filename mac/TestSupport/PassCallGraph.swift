import Foundation

// #4356 (plan v7 Phase 2): the functions the queue's render pass can reach, derived from the source.
//
// WHY THIS EXISTS. Plan v7 deletes every clock default "from `make`'s call graph" and guards the deletion with
// two scans over it (`PassClockScanTests`, `PassAmbientReadScanTests`), so the graph has to be derived from
// the code rather than written down: a hand-kept list of the pass's files is blind to the next function the
// pass starts calling, which is the one a scan exists to catch (L96).
//
// HOW IT RESOLVES A CALL, and what that misses, said plainly because it is text and not a type checker.
// Starting at `QueueRenderPass.make`, every reached body is read with comments and string contents removed
// (`SwiftSource`), and:
//
//   * `Type.member` follows that member of that type, in every file that declares or extends it;
//   * `Type(` follows that type's initialisers whose parameter labels the call's labels fit;
//   * a bare `name(` follows a function of the same name on the enclosing type;
//   * `something.name(` follows every FUNCTION named `name`, and `something.name` every COMPUTED property,
//     declared on a type the reached code has already MENTIONED by name. A type nobody in the pass names
//     cannot be the receiver of anything the pass calls, so a member on it is not followed until it is
//     (rapid type analysis, by name). A SwiftUI `View` is never followed: the pass returns values to views
//     and calls none of them.
//
// That over-approximates where two in-play types share a member name, which costs only an explicit `now:`
// at more call sites, the safe direction. What it cannot see: a call inside a string interpolation (string
// contents are removed), a member reached through a protocol requirement with no type named, a closure
// stored in a property and called later, and an initialiser reached only through `.init` on a value. Those
// are the guards' known blind spots, and `PassCallGraphTests` holds the graph to members the pass is known to
// call so a parser regression cannot shrink it to nothing quietly (L98).
enum PassCallGraph {

    enum Kind: Equatable, Sendable { case function, initializer, computed }

    struct Declaration: Hashable, Sendable {
        let file: String
        let type: String
        let name: String
        let kind: Kind
        let line: Int
        /// The text from the declaring keyword to the body's opening brace: its parameters and defaults.
        let header: String
        /// The body, braces included, with comments and string contents removed.
        let body: String

        var id: String { "\(type).\(name)@\(file):\(line)" }
    }

    struct Graph: Sendable {
        let declarations: [Declaration]
        let reached: [Declaration]
        let typesInPlay: Set<String>
        /// For each reached declaration, the one that first reached it and the name it was reached by.
        let reachedFrom: [String: (from: Declaration, via: String)]

        func contains(type: String, name: String) -> Bool {
            reached.contains { $0.type == type && $0.name == name }
        }

        /// How the pass reaches `d`, as a chain of `Type.name`, for a failure message.
        func path(to d: Declaration) -> String {
            var chain = ["\(d.type).\(d.name)"]
            var current = d
            var guardCount = 0
            while let step = reachedFrom[current.id], guardCount < 64 {
                chain.append("\(step.from.type).\(step.from.name)")
                current = step.from
                guardCount += 1
            }
            return chain.reversed().joined(separator: " > ")
        }
    }

    /// The render pass's graph, built once per process, since it is a pure function of the source tree.
    static let queuePass: Graph = build(files: AppSourceWalk.appFiles(), rootType: "QueueRenderPass",
                                        rootName: "make")

    /// The source a guard reads: comments and string contents removed, one line per source line.
    static func code(of text: String) -> String {
        let scan = SwiftSource.tokenize(text)
        let last = max(scan.codeLines.keys.max() ?? 0, 1)
        return (1...last).map { scan.codeLines[$0] ?? "" }.joined(separator: "\n")
    }

    static func build(files: [AppSourceWalk.File], rootType: String, rootName: String) -> Graph {
        var declarations: [Declaration] = []
        var viewTypes: Set<String> = []
        for file in files {
            let text = code(of: file.text)
            declarations += parse(text, file: file.name)
            viewTypes.formUnion(views(in: text))
        }
        let appTypes = Set(declarations.map(\.type))
        var byTypeAndName: [String: [Declaration]] = [:]
        var byName: [String: [Declaration]] = [:]
        for d in declarations {
            byTypeAndName["\(d.type).\(d.name)", default: []].append(d)
            byName[d.name, default: []].append(d)
        }

        var typesInPlay: Set<String> = []
        var waitingOnType: [String: [(Declaration, Declaration, String)]] = [:]
        var seen: Set<String> = []
        var reachedFrom: [String: (from: Declaration, via: String)] = [:]
        var work: [(Declaration, Declaration?, String)] =
            (byTypeAndName["\(rootType).\(rootName)"] ?? []).map { ($0, nil, "") }

        func enter(_ type: String) {
            guard appTypes.contains(type), !viewTypes.contains(type), !typesInPlay.contains(type) else { return }
            typesInPlay.insert(type)
            for (target, from, via) in waitingOnType.removeValue(forKey: type) ?? [] {
                work.append((target, from, via))
            }
        }

        while let (d, from, via) = work.popLast() {
            guard !seen.contains(d.id) else { continue }
            seen.insert(d.id)
            if let from { reachedFrom[d.id] = (from, via) }
            enter(d.type)
            for type in words(in: d.header + d.body, capitalised: true) { enter(type) }
            for call in calls(in: d.body) {
                let targets: [Declaration]
                switch call {
                case .qualified(let written, let name):
                    let type = written == "Self" ? d.type : written
                    targets = byTypeAndName["\(type).\(name)"] ?? []
                case .construction(let type, let labels):
                    targets = (byTypeAndName["\(type).init"] ?? []).filter { accepts($0, labels: labels) }
                case .bare(let name):
                    targets = byTypeAndName["\(d.type).\(name)"] ?? []
                case .member(let name, let isCall):
                    guard name != "init" else { continue }
                    let fitting = (byName[name] ?? []).filter { ($0.kind == .computed) != isCall }
                    var now: [Declaration] = []
                    for candidate in fitting {
                        if typesInPlay.contains(candidate.type) {
                            now.append(candidate)
                        } else {
                            waitingOnType[candidate.type, default: []].append((candidate, d, name))
                        }
                    }
                    targets = now
                }
                for target in targets { work.append((target, d, call.name)) }
            }
        }
        let reached = declarations.filter { seen.contains($0.id) }
        return Graph(declarations: declarations, reached: reached, typesInPlay: typesInPlay,
                     reachedFrom: reachedFrom)
    }

    // MARK: - Reading declarations

    private static let typeKeywords: Set<String> = ["struct", "enum", "class", "extension", "protocol", "actor"]

    /// Every function, initialiser and computed property declared inside a type in `text`.
    static func parse(_ text: String, file: String) -> [Declaration] {
        let chars = Array(text)
        var out: [Declaration] = []
        var stack: [(type: String, depth: Int)] = []
        var pendingType: String?
        var depth = 0
        var i = 0
        var line = 1

        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func word(at index: Int) -> (String, Int)? {
            guard index < chars.count, chars[index].isLetter || chars[index] == "_" else { return nil }
            if index > 0, isWordChar(chars[index - 1]) || chars[index - 1] == "." { return nil }
            var j = index
            while j < chars.count, isWordChar(chars[j]) { j += 1 }
            return (String(chars[index..<j]), j)
        }
        func skipSpaces(_ index: Int) -> Int {
            var j = index
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            return j
        }
        func matchingBrace(from open: Int) -> Int {
            var d = 0
            var k = open
            while k < chars.count {
                if chars[k] == "{" { d += 1 } else if chars[k] == "}" { d -= 1; if d == 0 { return k } }
                k += 1
            }
            return chars.count - 1
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; continue }
            if let (keyword, end) = word(at: i) {
                if typeKeywords.contains(keyword) {
                    let start = skipSpaces(end)
                    if let (name, after) = word(at: start) {
                        // `extension Outer.Inner` names Inner.
                        var full = name
                        var k = after
                        while k < chars.count, chars[k] == ".", let (next, nextEnd) = word(at: k + 1) {
                            full = next
                            k = nextEnd
                        }
                        pendingType = full
                        i = k
                        continue
                    }
                }
                if !stack.isEmpty, ["func", "init", "var", "subscript"].contains(keyword) {
                    let name: String
                    var cursor = end
                    if keyword == "func" || keyword == "var" {
                        guard let (n, after) = word(at: skipSpaces(end)) else { i = end; continue }
                        name = n
                        cursor = after
                    } else {
                        name = keyword
                    }
                    // Find the body's opening brace, or decide there is none.
                    var paren = 0
                    var j = cursor
                    var open: Int?
                    scan: while j < chars.count {
                        switch chars[j] {
                        case "(", "[": paren += 1
                        case ")", "]": paren -= 1
                        case "{": if paren <= 0 { open = j; break scan }
                        case "}": if paren <= 0 { break scan }
                        case "=": if keyword == "var", paren <= 0 { break scan }
                        case "\n": if keyword == "var", paren <= 0 { break scan }
                        default: break
                        }
                        j += 1
                    }
                    if let open {
                        let close = matchingBrace(from: open)
                        let kind: Kind = keyword == "var" ? .computed : (keyword == "func" ? .function : .initializer)
                        out.append(Declaration(file: file, type: stack[stack.count - 1].type, name: name, kind: kind,
                                               line: line, header: String(chars[i..<open]),
                                               body: String(chars[open...close])))
                        line += chars[i...close].filter { $0 == "\n" }.count
                        i = close + 1
                        continue
                    }
                }
                i = end
                continue
            }
            if c == "{" {
                depth += 1
                if let type = pendingType {
                    stack.append((type, depth))
                    pendingType = nil
                }
            } else if c == "}" {
                if let top = stack.last, top.depth == depth { stack.removeLast() }
                depth -= 1
            }
            i += 1
        }
        return out
    }

    /// Types declared or extended as a SwiftUI `View` in `text`.
    static func views(in text: String) -> Set<String> {
        guard let pattern = try? NSRegularExpression(
            pattern: #"\b(?:struct|class|extension)\s+(\w+)\s*:[^{]*\bView\b"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(pattern.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    // MARK: - Reading calls

    enum Call {
        case qualified(type: String, name: String)
        /// `Type(...)`, with the argument labels as written (`_` for an unlabelled one), so only the
        /// initialisers that call could reach are followed.
        case construction(type: String, labels: [String])
        case bare(name: String)
        case member(name: String, isCall: Bool)

        var name: String {
            switch self {
            case .qualified(_, let name), .bare(let name), .member(let name, _): return name
            case .construction(let type, _): return type
            }
        }
    }

    private static let callPattern = try! NSRegularExpression(
        pattern: #"(\b[A-Z]\w*)?(\s*\.\s*)?\b([A-Za-z_]\w*)\b(\s*[(:]?)"#)

    static func calls(in body: String) -> [Call] {
        var out: [Call] = []
        let range = NSRange(body.startIndex..., in: body)
        for match in callPattern.matches(in: body, range: range) {
            func group(_ n: Int) -> String? {
                Range(match.range(at: n), in: body).map { String(body[$0]) }
            }
            guard let name = group(3) else { continue }
            let type = group(1)
            let dotted = group(2) != nil
            let after = group(4)?.trimmingCharacters(in: .whitespaces) ?? ""
            // A capitalised word directly followed by `(` is a construction or a type's call syntax.
            if type == nil, !dotted, after == "(", name.first?.isUppercase == true {
                out.append(.construction(type: name, labels: labels(afterParenEndingAt: match.range, in: body)))
                continue
            }
            if let type, dotted {
                // `Outer.Inner(` builds the nested type, and `Self.member` is the enclosing type's own.
                if name.first?.isUppercase == true {
                    if after == "(" {
                        out.append(.construction(type: name, labels: labels(afterParenEndingAt: match.range,
                                                                            in: body)))
                    }
                } else {
                    out.append(.qualified(type: type, name: name))
                }
            } else if dotted {
                if after == ":" { continue }   // an argument label after a dot is not possible; a ternary is
                out.append(.member(name: name, isCall: after == "("))
            } else if after == "(" {
                out.append(.bare(name: name))
            }
        }
        return out
    }

    /// The argument labels of the call whose `(` ends `range`, `_` for each unlabelled argument.
    static func labels(afterParenEndingAt range: NSRange, in body: String) -> [String] {
        let chars = Array(body.utf16)
        var i = range.location + range.length
        guard i > 0, i <= chars.count, chars[i - 1] == UInt16(UInt8(ascii: "(")) else { return [] }
        var depth = 0
        var current = ""
        var parts: [String] = []
        while i < chars.count {
            let c = Character(UnicodeScalar(chars[i]) ?? " ")
            if c == "(" || c == "[" || c == "{" { depth += 1 }
            if c == ")" || c == "]" || c == "}" {
                if depth == 0 { break }
                depth -= 1
            }
            if c == ",", depth == 0 { parts.append(current); current = "" } else { current.append(c) }
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        return parts.map { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { return "_" }
            let head = trimmed[..<colon]
            return head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) && !head.isEmpty
                ? String(head) : "_"
        }
    }

    /// Whether an initialiser could be the one a construction with these labels calls: the call's labels
    /// are its parameters' labels in order, leaving out only parameters that have a default.
    static func accepts(_ initializer: Declaration, labels: [String]) -> Bool {
        guard let open = initializer.header.firstIndex(of: "("),
              let close = initializer.header.lastIndex(of: ")"), open < close else { return true }
        var depth = 0
        var current = ""
        var parameters: [(label: String, defaulted: Bool)] = []
        func finish() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !trimmed.isEmpty else { return }
            let label = String(trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            parameters.append((label.isEmpty ? "_" : label, trimmed.contains("=")))
        }
        for c in initializer.header[initializer.header.index(after: open)..<close] {
            if c == "(" || c == "[" || c == "{" { depth += 1 }
            if c == ")" || c == "]" || c == "}" { depth -= 1 }
            if c == ",", depth == 0 { finish() } else { current.append(c) }
        }
        finish()
        var index = 0
        for parameter in parameters {
            if index < labels.count, labels[index] == parameter.label {
                index += 1
            } else if !parameter.defaulted {
                return false
            }
        }
        return index == labels.count
    }

    /// The whole words in `text`, optionally only those starting with a capital letter.
    static func words(in text: String, capitalised: Bool) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        for c in text {
            if c.isLetter || c.isNumber || c == "_" {
                current.append(c)
            } else {
                if !current.isEmpty, !capitalised || current.first?.isUppercase == true { out.insert(current) }
                current = ""
            }
        }
        if !current.isEmpty, !capitalised || current.first?.isUppercase == true { out.insert(current) }
        return out
    }
}
