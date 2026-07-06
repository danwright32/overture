import Foundation

// Shared by guard tests that assert something about one function's body without invoking it
// directly, e.g. a SwiftUI View's @Environment/@Query-backed handler that isn't unit-testable
// in isolation. Extracts `func <name>(...) { ... }` from source text by counting braces from
// the signature's opening brace to its matching close, so a check can scope to just that
// function instead of the whole file.
enum SourceGuard {
    enum GuardError: Error {
        case functionNotFound(String)
        case unbalancedBraces(String)
    }

    static func functionBody(named name: String, in src: String) throws -> Substring {
        guard let signatureRange = src.range(of: "func \(name)(") else {
            throw GuardError.functionNotFound(name)
        }
        // Balance parens across the parameter list first, so a default parameter value that is
        // itself a closure literal (with its own "{"/"(") can't be mistaken for the function
        // body's opening brace: naively taking the first "{" after the signature would land
        // inside that closure literal instead, silently scanning the wrong (and usually much
        // smaller) span.
        var parenDepth = 1
        var index = signatureRange.upperBound
        while index < src.endIndex, parenDepth > 0 {
            switch src[index] {
            case "(": parenDepth += 1
            case ")": parenDepth -= 1
            default: break
            }
            index = src.index(after: index)
        }
        guard parenDepth == 0 else { throw GuardError.functionNotFound(name) }
        guard let openBrace = src[index...].firstIndex(of: "{") else {
            throw GuardError.functionNotFound(name)
        }
        var depth = 0
        var bodyIndex = openBrace
        while bodyIndex < src.endIndex {
            switch src[bodyIndex] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return src[openBrace...bodyIndex]
                }
            default: break
            }
            bodyIndex = src.index(after: bodyIndex)
        }
        throw GuardError.unbalancedBraces(name)
    }
}
