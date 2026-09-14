import Foundation

// #3345. Whether a check followed its own waterfall step (b), read from the evidence the check produced.
//
// `docs/prep-runbook.md` requires a fetch of the target's canonical `firstnamelastname.com` before any
// answer about them is final. #2265 measured that step being skipped on 2026-08-07, and #3345 measured
// the consequence: 31 of the 37 shows the check wrote off as `named_but_no_route` later turned out to
// hold a route, usually on the person's OWN domain.
//
// WHY THIS READS THE STREAM RATHER THAN ASKING THE RUN. The obvious alternative is a declared field
// (`canonicalDomainTried`), the shape #2895 and #2912 use. It would be a claim the run makes about
// itself, written by the same prompt that skipped the step, and a model that reads the code consuming
// its output derives its contract from that code's permissiveness (L167, L27, L128). The run's tool
// calls are recorded whatever it believes about itself, so this asks the record.
//
// IT READS AND JUDGES; IT REFUSES NOTHING. Dan's call, 2026-09-06. The mechanism #3345 proposes could
// not be reproduced on any run whose behaviour is on disk: streams have only been kept per run since
// #3446, exactly one run has them, and on that run all nine named people had their own domain fetched.
// Enforcing on a signal nobody has measured on live traffic is how a guard comes to fire on the ordinary
// case and be switched off within a day (L506, L93, L142).
enum CanonicalDomainProcedure {

    // Three outcomes, not two, and the third is the one that matters. A name with no canonical domain to
    // try (a one-word act, a company) is UNANSWERABLE, and folding it into `notTried` would report this
    // reader's own blind spot as a finding about the check (L11, L98).
    enum Judgement: Equatable, Sendable {
        case tried
        case notTried
        case noCanonicalDomainToTry
    }

    // The domain the runbook asks the run to try: the person's name with everything but letters and
    // digits removed, accents folded, lowercased. `Oc\u{00E9}ane Vireux` becomes `oceanevireux`, which is
    // what a domain for her would be spelled as.
    //
    // TWO WORDS MINIMUM, and that bound is the guard against this rule reaching past what it was written
    // for. Step (b) is about a named PERSON's own site. One word is a company, a stage name or an act,
    // and `sohoplayhouse` would match the venue's own domain on every show in that room, so every such
    // show would read as compliant for a reason that has nothing to do with the person.
    static func canonicalToken(forName name: String?) -> String? {
        guard let name else { return nil }
        let folded = name.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard words.count >= 2 else { return nil }
        return words.joined().lowercased()
    }

    // The hosts the run actually FETCHED, out of its own event stream.
    //
    // A WebSearch is deliberately not one of them. #2265's whole finding is a run that found a doorway
    // and did not open it, so counting a search that merely names somebody as having tried their site
    // would report the exact failure this exists to see as compliance.
    //
    // A line that will not parse is skipped rather than counted or thrown on: a stream is appended to by
    // another process while a run is live, so a half-written last line is the ordinary state.
    static func fetchedHosts(inStreamLines lines: [String]) -> Set<String> {
        var hosts: Set<String> = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(StreamEvent.self, from: data)
            else { continue }
            for block in event.message?.content ?? [] {
                guard block.type == "tool_use", block.name == "WebFetch",
                      let raw = block.input?.url,
                      let host = URL(string: raw)?.host?.lowercased()
                else { continue }
                hosts.insert(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            }
        }
        return hosts
    }

    // The two fields of a stream line this reader needs, and nothing else. Decoded by named key rather
    // than walked as a dictionary, so a line whose `content` is a plain string (which many event types
    // carry) throws and is skipped rather than being probed shape by shape.
    private struct StreamEvent: Decodable {
        struct Input: Decodable { var url: String? }
        struct Block: Decodable {
            var type: String?
            var name: String?
            var input: Input?
        }
        struct Message: Decodable { var content: [Block]? }
        var message: Message?
    }

    static func judgement(name: String?, fetchedHosts: Set<String>) -> Judgement {
        guard let token = canonicalToken(forName: name) else { return .noCanonicalDomainToTry }
        return fetchedHosts.contains(where: { matches(token: token, host: $0) }) ? .tried : .notTried
    }

    // The host is flattened the same way the name is before they are compared, because a real domain
    // carries separators a name does not: the 2026-08-30 run fetched `rebeccastevens-walter.com` for
    // somebody billed as Rebecca Stevens Walter, and comparing the raw host would have called that a
    // skipped step, which is a false accusation about a run that complied.
    //
    // CONTAINMENT rather than equality, so a subdomain of their own site counts (`baileyswilley.substack.com`
    // is in the same run's evidence) and so does any TLD. That is the permissive direction on purpose:
    // this reading exists to find a step that was NOT taken, and every doubt it cannot settle should fall
    // toward saying the run complied rather than toward accusing it (L93, L119).
    private static func matches(token: String, host: String) -> Bool {
        host.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined()
            .contains(token)
    }
}
