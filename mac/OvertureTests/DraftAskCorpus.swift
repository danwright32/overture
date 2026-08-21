import Foundation

// #2949: every compliant drafted body this repo holds, for calibrating a wording rule against what Dan's
// own drafts actually do.
//
// A rule that fires on his proven drafts is one he turns off (L93), so a fixture somebody chose is not
// enough: the rule has to be scored against the whole corpus. `fixtures/draft-ask/cases.json` already
// collects the accepting bodies from `fixtures/prep-eval`, and #2954 keeps each one matching the fixture
// it came from, so reading it here is reading the real drafts rather than a copy that has drifted.
enum DraftAskCorpus {
    static func acceptingBodies() -> [String]? {
        let url = RepoRoot.url.appendingPathComponent("fixtures/draft-ask/cases.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = json["cases"] as? [[String: Any]] else { return nil }
        return cases.compactMap { $0["asks"] as? Bool == true ? $0["body"] as? String : nil }
    }
}
