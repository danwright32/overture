import Foundation

// #3852: the region ONE REDRAW of a SwiftUI view evaluates, and the declarations it reaches, as one
// implementation two guards share.
//
// WHY IT MOVED HERE. #3829 built this walk inside `ACostInstrumentEnumeratesItsSubjectsTests` to answer
// one question: is every Domain type a redraw runs named by the instrument that claims to price that
// redraw. #3852 asks a different question of the same region: is any single derivation in it evaluated
// more than once per draw. Copying the walk would be two things doing one job, and the day one of them
// learned to follow a new declaration shape and the other did not is the day the two guards disagreed
// about what a redraw even reaches, silently, in whichever direction was cheaper to not notice (L41,
// L370). One walk, two readers.
//
// WHAT IT IS. A view's `body`, plus every property and function declared in that file which the body
// reaches, followed TRANSITIVELY to a fixed point. The transitive step is the whole point and is #3829's
// own finding: `SourcesView.roomContext` is not named in `body` at all, it is reached through
// `makeRenderData()`, and one level of following would have stopped above it. That is exactly how a
// 69 ms call stayed invisible for days.
//
// WHAT IT IS NOT, said here rather than left for each reader to rediscover. It is text. It cannot tell a
// reference inside an escaping closure (evaluated when somebody presses something) from one in the body
// (evaluated every draw), it cannot see a cost inside a type it only names, and it does not know how many
// times SwiftUI evaluates the body. Each reader states what its own answer therefore claims.
enum RedrawRegion {

    /// The source with line comments removed, so a name mentioned in prose is never mistaken for a
    /// reference to it. Every function here takes source that has been through this.
    static func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[line.startIndex..<range.lowerBound]
        }.joined(separator: "\n")
    }

    /// One property or function this file declares, with the body a reader can search.
    struct Declaration {
        let name: String
        let body: String
        /// The line the declaration opens on, in the COMMENT-STRIPPED source, so a reader can exclude a
        /// declaration's own body when counting references to it elsewhere.
        let line: Int
        /// How many lines the declaration spans, same source.
        let span: Int
    }

    /// Every property and function declared in this file, by name.
    ///
    /// FIRST DECLARATION WINS, which is what the `declarations[name] == nil` guard says. A name declared
    /// twice in one file (an overload, or a nested type's member) would otherwise have the two bodies
    /// silently replace each other, and which one survived would depend on file order.
    static func declarations(in strippedSource: String) -> [String: Declaration] {
        var declarations: [String: Declaration] = [:]
        let lines = strippedSource.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["private var ", "private func ", "var ", "func "] where trimmed.hasPrefix(prefix) {
                let rest = trimmed.dropFirst(prefix.count)
                let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard !name.isEmpty, declarations[name] == nil else { continue }
                let body: String
                if trimmed.hasPrefix("private func ") || trimmed.hasPrefix("func ") {
                    body = SourceGuardHelper.bodyOfFunction(named: name, in: strippedSource) ?? ""
                } else {
                    // THE MARKER IS THE DECLARATION LINE UP TO AND INCLUDING ITS OPENING BRACE, and
                    // getting that wrong is what #3852 found here. `propertyBody` balances from the end
                    // of the marker with the depth already at one, so the marker has to END with the
                    // brace. The walk this was lifted from appended `" {"` unconditionally, and a
                    // declaration line already ending in `{` therefore became a marker ending `{ {`,
                    // which matches nothing. Measured on the app 2026-09-12: NOT ONE `var` in
                    // `SourcesView` or `QueueView` resolved a body, so the walk followed functions only
                    // and its own comment claiming "every private property and function the body
                    // reaches" was describing something it never did (L400). Fixing it made six more
                    // Domain types visible on the Sources sheet and two more on the queue.
                    let marker = trimmed.hasSuffix("{") ? trimmed : trimmed + " {"
                    body = SourceGuardHelper.propertyBody(marker, in: strippedSource) ?? ""
                }
                declarations[name] = Declaration(name: name, body: body, line: index,
                                                 span: body.isEmpty
                                                     ? 1 : body.components(separatedBy: "\n").count + 1)
                break
            }
        }
        return declarations
    }

    /// The region one redraw evaluates: `body` plus every declaration it reaches, transitively.
    /// Empty when the view has no `body`, which every caller must treat as UNMEASURED rather than as a
    /// view with no derivations in it (L98).
    static func of(_ view: String) -> String {
        let source = code(view)
        var region = SourceGuardHelper.propertyBody("var body: some View {", in: source) ?? ""
        guard !region.isEmpty else { return "" }

        let declarations = declarations(in: source)

        // Followed to a FIXED POINT rather than one level deep. See the header.
        var seen: Set<String> = []
        var changed = true
        while changed {
            changed = false
            for (name, declaration) in declarations
            where !seen.contains(name) && !declaration.body.isEmpty && region.contains(name) {
                seen.insert(name)
                region += "\n" + declaration.body
                changed = true
            }
        }
        return region
    }
}
