import Foundation

// #4329 (A12), shared with #4370 (B1): every write to the store a stretch of app code can reach, derived
// from the source rather than listed from call sites (L247, L96).
//
// WHY A SCAN. A12's rule is "the read phase writes nothing to the store". The read phase is not one
// function: it is everything an entry point does before its landing block, and everything THAT calls,
// across files (`SourceCheck.decide` in the Domain layer wrote six fields on every fetch). A list of the
// sites somebody remembered would check only those, so the list is derived: the region's own lines, then
// every app function its calls resolve to, transitively, and every store write in any of them.
//
// WHAT COUNTS AS A STORE WRITE, derived from the models rather than named here:
//   - an assignment (or `+=`, `-=`, ...) to a stored property of any model, or to a computed property a
//     model declares with a setter (`WatchedSource.health` writes `healthRaw`): `x.notes = ...`;
//   - a mutating collection call on one (`x.labels.append(...)`);
//   - a call to a MUTATOR: a method a model declares whose body writes one of its own stored properties, or
//     calls another mutator (`recordFailedRead` writes `lastCheckedAt`, `health` and the streak);
//   - `insert(`, `delete(` and `save()` on a context.
// The stored property names come from the caller (a TestSupport file cannot name app types, so the test
// hands over the Schema's own attribute names), which keeps the vocabulary the one SwiftData persists.
//
// WHAT IT CANNOT SEE, stated so nobody reads its silence as more than it is:
//   - A call through a VALUE (`landing.noteReconcile(...)`, `extractor.extract()`, an injected closure) is
//     not followed, because which function it reaches is decided by a type this scan does not check. A
//     mutator is still recognised by name on any receiver, which is the shape a model write takes.
//   - Names are not type checked: a write to a property of a non-model value that shares a model property's
//     name (`page.notes = `) is reported. That direction is the safe one, and a caller classifies it.
//   - A write behind a dynamic member, a key path or `setValue(_:forKey:)`.
// A12 pairs it with a runtime check in the other direction (`context.hasChanges` at every read-phase
// await), and B1 with the didSave sets of a real landing, so each catches what the other cannot.
//
// HOW B1 (#4370) REUSES IT. Everything here is general: `Index` over any set of files, `Vocabulary` from
// any set of models, `writes(in:)` over any lines, `reachable(from:)` from any region. A12 asks one
// question of it (`writesReachable(fromRegionOf:endingBefore:)`, the read phase of an entry point). B1's
// type list is the same derivation asked of the whole landing (the region running to the closing save,
// rather than stopping at the token), plus `Index.functions` filtered to the between-turn writers, with
// each site's `Site.kind` naming the entity through `Vocabulary.entities(owning:)`.
enum StoreWriteScan {

    // One function declared in app code: a method, a static, or a function nested inside another.
    struct Function: Hashable, CustomStringConvertible {
        let file: String
        let owner: String?          // the innermost type or extension it is declared in
        let name: String
        let firstLine: Int          // its `func` line
        let bodyLine: Int           // the line holding its body's opening brace
        let lastLine: Int           // the line holding its closing brace
        var qualifiedName: String { owner.map { "\($0).\(name)" } ?? name }
        var description: String { "\(qualifiedName) (\(file):\(firstLine))" }
    }

    // One store write the scan found.
    struct Site: Hashable, CustomStringConvertible {
        enum Kind: Hashable, CustomStringConvertible {
            case assigns(String)    // a model property, stored or written through a setter
            case mutator(String)    // a model method that writes its own row
            case inserts, deletes, saves
            var description: String {
                switch self {
                case .assigns(let p): return "assigns \(p)"
                case .mutator(let m): return "calls mutator \(m)"
                case .inserts: return "inserts"
                case .deletes: return "deletes"
                case .saves: return "saves"
                }
            }
        }
        let file: String
        let line: Int
        let function: String
        let kind: Kind
        // The site's identity for a classification table: stable across line drift, unlike `line`.
        var key: String { "\(function) \(kind)" }
        var description: String { "\(file):\(line) \(function) \(kind)" }
    }

    // MARK: - Index

    struct Index {
        // file name -> its code lines in order, comments and string contents removed
        // (`SwiftSource.Scan.codeLines`).
        let code: [String: [(line: Int, code: String)]]
        let functions: [Function]
        // Computed properties declared WITH a body, by owner, so the vocabulary can find setters.
        let properties: [Function]
        private let byOwnerAndName: [String: [Function]]

        init(files: [(name: String, text: String)]) {
            var code: [String: [(line: Int, code: String)]] = [:]
            var functions: [Function] = []
            var properties: [Function] = []
            for file in files {
                let lines = SwiftSource.tokenize(file.text).codeLines
                code[file.name] = lines.keys.sorted().map { (line: $0, code: lines[$0]!) }
                let parsed = Self.declarations(in: lines, file: file.name)
                functions += parsed.functions
                properties += parsed.properties
            }
            self.code = code
            self.functions = functions
            self.properties = properties
            self.byOwnerAndName = Dictionary(grouping: functions) { "\($0.owner ?? "")\u{1F}\($0.name)" }
        }

        // A function's own lines, its signature included.
        func lines(of function: Function) -> [(line: Int, code: String)] {
            lines(in: function.file, from: function.firstLine, through: function.lastLine)
        }

        func lines(in file: String, from first: Int, through last: Int) -> [(line: Int, code: String)] {
            guard let all = code[file] else { return [] }
            // Binary search for the first line, since this is asked once per function the walk reaches.
            var low = 0, high = all.count
            while low < high {
                let mid = (low + high) / 2
                if all[mid].line < first { low = mid + 1 } else { high = mid }
            }
            var out: [(line: Int, code: String)] = []
            var i = low
            while i < all.count, all[i].line <= last { out.append(all[i]); i += 1 }
            return out
        }

        // The functions named `name`, declared in a type or extension named `owner`.
        func functions(named name: String, owner: String?) -> [Function] {
            byOwnerAndName["\(owner ?? "")\u{1F}\(name)"] ?? []
        }

        // A function's BODY: from its opening brace, signature and default arguments left out. What a model's
        // own method writes is judged on this, so a parameter's default is never read as a write to the row.
        func bodyLines(of function: Function) -> [String] {
            var out = lines(in: function.file, from: function.bodyLine, through: function.lastLine).map(\.code)
            if let first = out.first, let brace = first.firstIndex(of: "{") {
                out[0] = String(first[first.index(after: brace)...])
            }
            return out
        }

        private enum DeclKind { case type(String), function(String), property(String) }
        private struct Open { let kind: DeclKind?; let line: Int; let bodyLine: Int; let owner: String? }

        private static let typeDecl = try! NSRegularExpression(
            pattern: #"(?:^|[\s(])(?:enum|struct|class|actor|extension|protocol)\s+([A-Z][A-Za-z0-9_]*)"#)
        private static let funcDecl = try! NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        private static let varDecl = try! NSRegularExpression(pattern: #"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)\s*:"#)

        private static func first(_ re: NSRegularExpression, in s: String) -> String? {
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }

        // Brace and paren matching over code with strings and comments gone. A declaration's body is the
        // first `{` at its own paren depth after it, so a default closure in a long parameter list (runScout's
        // run to dozens of lines) is not mistaken for the body.
        private static func declarations(in lines: [Int: String], file: String)
            -> (functions: [Function], properties: [Function]) {
            var functions: [Function] = []
            var properties: [Function] = []
            var stack: [Open] = []
            var pending: (kind: DeclKind, line: Int, parens: Int)?
            func owner() -> String? {
                for open in stack.reversed() { if case .type(let name)? = open.kind { return name } }
                return nil
            }
            for number in lines.keys.sorted() {
                let text = lines[number]!
                if let name = first(funcDecl, in: text) {
                    pending = (.function(name), number, 0)
                } else if let name = first(typeDecl, in: text) {
                    pending = (.type(name), number, 0)
                } else if let name = first(varDecl, in: text),
                          text.trimmingCharacters(in: .whitespaces).hasSuffix("{") {
                    pending = (.property(name), number, 0)
                }
                for character in text {
                    switch character {
                    case "(":
                        if pending != nil { pending!.parens += 1 }
                    case ")":
                        if pending != nil { pending!.parens -= 1 }
                    case "{":
                        if let p = pending, p.parens == 0 {
                            stack.append(Open(kind: p.kind, line: p.line, bodyLine: number, owner: owner()))
                            pending = nil
                        } else {
                            stack.append(Open(kind: nil, line: number, bodyLine: number, owner: owner()))
                        }
                    case "}":
                        guard let open = stack.popLast() else { continue }
                        switch open.kind {
                        case .function(let name)?:
                            functions.append(Function(file: file, owner: open.owner, name: name,
                                                      firstLine: open.line, bodyLine: open.bodyLine, lastLine: number))
                        case .property(let name)?:
                            properties.append(Function(file: file, owner: open.owner, name: name,
                                                       firstLine: open.line, bodyLine: open.bodyLine, lastLine: number))
                        default: break
                        }
                        // A requirement with no body (a protocol's `func f()`) leaves nothing pending past
                        // the brace that closes its declaration.
                        if pending != nil, pending!.parens == 0 { pending = nil }
                    default: break
                    }
                }
            }
            return (functions, properties)
        }
    }

    // MARK: - Vocabulary

    struct Vocabulary {
        // Every model property a write to which reaches the store: the stored ones, and the computed ones a
        // model declares with a setter.
        let properties: Set<String>
        // Every model method that writes its own row, directly or through another mutator.
        let mutators: Set<String>
        // entity -> the names above that belong to it, so a site can be traced to the type it writes.
        let byEntity: [String: Set<String>]

        func entities(owning name: String) -> [String] {
            byEntity.filter { $0.value.contains(name) }.map(\.key).sorted()
        }
    }

    // A write to a name on the row itself, inside the model's own code: `name = `, `self.name += `,
    // `name.append(`.
    private static let bareWrite = try! NSRegularExpression(
        pattern: #"(?<![\w.])(?:self\.)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:[-+*/]?=(?!=)|\.(?:append|insert|remove\w*|sort)\()"#)
    // A call to a method on the row itself: `name(` or `self.name(`.
    private static let selfCall = try! NSRegularExpression(pattern: #"(?<![\w.])(?:self\.)?([A-Za-z_][A-Za-z0-9_]*)\s*\("#)

    private static func names(_ re: NSRegularExpression, in lines: [String]) -> Set<String> {
        var out: Set<String> = []
        for s in lines {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range(at: 1), in: s) { out.insert(String(s[r])) }
            }
        }
        return out
    }

    // `stored`: entity name -> its stored property names, as SwiftData persists them.
    static func vocabulary(stored: [String: Set<String>], index: Index) -> Vocabulary {
        var byEntity = stored
        // Computed properties with a setter that writes a stored one.
        for property in index.properties {
            guard let owner = property.owner, let names = stored[owner] else { continue }
            let body = index.bodyLines(of: property)
            guard body.contains(where: { $0.range(of: #"\bset\b"#, options: .regularExpression) != nil }) else { continue }
            if !Self.names(bareWrite, in: body).isDisjoint(with: names) {
                byEntity[owner, default: []].insert(property.name)
            }
        }
        // Each model method's own writes and own calls, read once.
        let methods: [(function: Function, writes: Set<String>, calls: Set<String>)] = index.functions.compactMap { f in
            guard let owner = f.owner, byEntity[owner] != nil else { return nil }
            let body = index.bodyLines(of: f)
            return (f, Self.names(bareWrite, in: body), Self.names(selfCall, in: body))
        }
        // Mutators, to a fixed point: a method calling another mutator is one too.
        var mutators: Set<String> = []
        var grew = true
        while grew {
            grew = false
            for (function, written, called) in methods {
                guard let owner = function.owner, let names = byEntity[owner],
                      !mutators.contains(function.name) else { continue }
                let writes = !written.isDisjoint(with: names)
                let delegates = !called.isDisjoint(with: mutators)
                if writes || delegates {
                    mutators.insert(function.name)
                    byEntity[owner, default: []].insert(function.name)
                    grew = true
                }
            }
        }
        let properties = byEntity.values.reduce(into: Set<String>()) { $0.formUnion($1) }.subtracting(mutators)
        return Vocabulary(properties: properties, mutators: mutators, byEntity: byEntity)
    }

    // MARK: - Writes

    private static let memberWrite = try! NSRegularExpression(
        pattern: #"\.([A-Za-z_][A-Za-z0-9_]*)\s*(?:[-+*/]?=(?!=)|\.(?:append|insert|remove\w*|sort)\()"#)
    private static let memberCall = try! NSRegularExpression(pattern: #"\.([A-Za-z_][A-Za-z0-9_]*)\s*\("#)
    private static let contextVerb = try! NSRegularExpression(
        pattern: #"\b(?:\w*[cC]ontext|ctx)\??\.(insert|delete)\("#)
    private static let save = try! NSRegularExpression(pattern: #"\.save\(\)"#)

    private static func captures(_ re: NSRegularExpression, in s: String) -> [String] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: m.numberOfRanges > 1 ? 1 : 0), in: s).map { String(s[$0]) }
        }
    }

    // Every store write on these lines. `function` names where they sit, for the report.
    static func writes(in lines: [(line: Int, code: String)], file: String, function: String,
                       vocabulary: Vocabulary) -> [Site] {
        var sites: [Site] = []
        for (line, code) in lines {
            for name in captures(memberWrite, in: code) where vocabulary.properties.contains(name) {
                sites.append(Site(file: file, line: line, function: function, kind: .assigns(name)))
            }
            for name in captures(memberCall, in: code) where vocabulary.mutators.contains(name) {
                sites.append(Site(file: file, line: line, function: function, kind: .mutator(name)))
            }
            for verb in captures(contextVerb, in: code) {
                sites.append(Site(file: file, line: line, function: function,
                                  kind: verb == "insert" ? .inserts : .deletes))
            }
            if !captures(save, in: code).isEmpty {
                sites.append(Site(file: file, line: line, function: function, kind: .saves))
            }
        }
        return sites
    }

    // MARK: - Calls

    private static let qualifiedCall = try! NSRegularExpression(
        pattern: #"\b([A-Z][A-Za-z0-9_]*)\.([a-z_][A-Za-z0-9_]*)\s*\("#)
    // Not after `func `, which is the declaration rather than a call: a function's own signature would
    // otherwise call itself, and an entry point's region would reach its own landing block.
    private static let bareCall = try! NSRegularExpression(pattern: #"(?<![\w.])(?<!func )([a-z_][A-Za-z0-9_]*)\s*\("#)
    private static let notCalls: Set<String> = [
        "if", "guard", "switch", "for", "while", "return", "func", "init", "catch", "case", "let", "var",
        "await", "try", "throw", "repeat", "in", "where", "as", "is", "some", "any", "super", "self",
    ]

    // The app functions these lines call by name: `Type.name(` resolves to that type's functions (in any
    // file), `Self.name(` and a bare `name(` to the enclosing type's own, nested functions included.
    static func callees(of lines: [(line: Int, code: String)], file: String, owner: String?,
                        index: Index) -> Set<Function> {
        var out: Set<Function> = []
        for (_, code) in lines {
            let range = NSRange(code.startIndex..., in: code)
            for m in qualifiedCall.matches(in: code, range: range) {
                guard let t = Range(m.range(at: 1), in: code), let n = Range(m.range(at: 2), in: code) else { continue }
                let type = String(code[t]) == "Self" ? owner : String(code[t])
                out.formUnion(index.functions(named: String(code[n]), owner: type))
            }
            for m in bareCall.matches(in: code, range: range) {
                guard let n = Range(m.range(at: 1), in: code) else { continue }
                let name = String(code[n])
                guard !notCalls.contains(name) else { continue }
                out.formUnion(index.functions(named: name, owner: owner).filter { $0.file == file })
            }
        }
        return out
    }

    // Every function reachable from `lines`, transitively, the region's own nested functions included.
    static func reachable(from lines: [(line: Int, code: String)], file: String, owner: String?,
                          index: Index) -> Set<Function> {
        var seen: Set<Function> = []
        var frontier = callees(of: lines, file: file, owner: owner, index: index)
        while let next = frontier.popFirst() {
            guard seen.insert(next).inserted else { continue }
            frontier.formUnion(callees(of: index.lines(of: next), file: next.file, owner: next.owner, index: index)
                .subtracting(seen))
        }
        return seen
    }

    // The question A12 asks: every store write reachable from an entry point's body up to (not including)
    // the first line containing `boundary`, which for a scout landing is where it takes the store
    // (`landings.begin(`). A boundary the body does not contain is a refusal, never the whole body: a
    // renamed token call must not silently widen the region into the landing block and report its writes,
    // nor narrow it to nothing.
    struct Region {
        let entry: Function
        let lines: [(line: Int, code: String)]
        let reached: Set<Function>
        let sites: [Site]
    }

    enum Refusal: Error, CustomStringConvertible {
        case noEntry(String), ambiguousEntry(String, Int), noBoundary(String, String)
        var description: String {
            switch self {
            case .noEntry(let n): return "no function \(n) was found, so its read phase was not scanned"
            case .ambiguousEntry(let n, let c): return "\(c) functions match \(n), so which read phase to scan is unknown"
            case .noBoundary(let n, let b): return "\(n) holds no line containing \(b), so where its read phase ends is unknown"
            }
        }
    }

    static func writesReachable(fromRegionOf name: String, owner: String, endingBefore boundary: String,
                                index: Index, vocabulary: Vocabulary) throws -> Region {
        let candidates = index.functions(named: name, owner: owner)
        guard let entry = candidates.first else { throw Refusal.noEntry("\(owner).\(name)") }
        guard candidates.count == 1 else { throw Refusal.ambiguousEntry("\(owner).\(name)", candidates.count) }
        let body = index.lines(of: entry)
        guard let end = body.first(where: { $0.code.contains(boundary) })?.line else {
            throw Refusal.noBoundary(entry.qualifiedName, boundary)
        }
        let region = body.filter { $0.line < end }
        let reached = reachable(from: region, file: entry.file, owner: entry.owner, index: index)
        // The region's own nested functions are already in its lines; scanning them again as callees would
        // report each of their writes twice.
        let outside = reached.filter { !($0.file == entry.file && $0.firstLine >= entry.firstLine && $0.lastLine < end) }
        var sites = writes(in: region, file: entry.file, function: entry.qualifiedName, vocabulary: vocabulary)
        for function in outside.sorted(by: { ($0.file, $0.firstLine) < ($1.file, $1.firstLine) }) {
            sites += writes(in: index.lines(of: function), file: function.file, function: function.qualifiedName,
                            vocabulary: vocabulary)
        }
        return Region(entry: entry, lines: region, reached: reached, sites: sites)
    }
}
