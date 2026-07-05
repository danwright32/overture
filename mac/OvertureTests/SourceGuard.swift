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
        guard let openBrace = src[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw GuardError.functionNotFound(name)
        }
        var depth = 0
        var index = openBrace
        while index < src.endIndex {
            switch src[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return src[openBrace...index]
                }
            default: break
            }
            index = src.index(after: index)
        }
        throw GuardError.unbalancedBraces(name)
    }
}
