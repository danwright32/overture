import Foundation

// #885: one pluralizer.
//
// This was being done by hand, inline, in a SwiftUI body, in six places across five files, with a
// slightly different ternary each time (`n == 1 ? "" : "s"`, `n == 1 ? "s" : ""` where the VERB is what
// agrees, `count == 1 ? "Added 1 show" : "Added \(count) shows"`). AgentRoster had a private `shows(_:)`
// of its own the whole time, which is the tell: the codebase already knew this belonged in the domain.
//
// No single one of those was a bug. That is exactly the point of #885: the same small decision restated
// everywhere, until one copy of it is wrong and nothing anywhere can tell.
enum Plural {
    // "1 show", "2 shows", "0 shows". Zero is plural in English, which a hand-written `n > 1` gets
    // wrong and a hand-written `n == 1` gets right by accident.
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(word(n, singular, plural))"
    }

    // An irregular plural is spelled out rather than guessed at by bolting on an "s".
    static func word(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        n == 1 ? singular : (plural ?? singular + "s")
    }
}
