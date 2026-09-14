import Foundation

// The files Claude Code loads AUTOMATICALLY into every session (#3640).
//
// Until the split there was one of them, `AGENTS.md`, and every guard over what the instructions say
// read that single path. #3640 moved the BODIES of those instructions into `docs/agents/`, leaving an
// index behind, so a guard still reading only `AGENTS.md` would keep passing while covering a
// fraction of what it did: the paragraphs most likely to carry a drifting hand-written number are
// exactly the ones that moved. An exemption that is correct still leaves its content with no reviewer
// unless one is named in the same change (L129).
//
// DERIVED from the directory rather than listed in a constant, so a seventh topic file joins every
// guard by existing rather than by somebody remembering to add it to a registry (L96).
enum AgentInstructionDocs {

    // Where the moved bodies live, relative to the repo root.
    static let topicsDirectory = "docs/agents"

    struct Doc {
        let name: String        // repo-relative, for a failure message that names the file to edit
        let text: String
    }

    // Every always-loaded instructions file, index first, then the topic files in name order.
    //
    // It THROWS rather than returning what it managed to find, because a guard handed a short list
    // passes over the part it could not read, and passing is indistinguishable from having nothing to
    // find (L98, L11). The two ways this can go quietly wrong, the index being unreadable and the
    // topics directory being empty, each get their own message rather than one shared one (L11).
    static func all() throws -> [Doc] {
        let root = RepoRoot.url
        let indexURL = root.appendingPathComponent("AGENTS.md")
        let index = Doc(name: "AGENTS.md", text: try String(contentsOf: indexURL, encoding: .utf8))

        let topicsURL = root.appendingPathComponent(topicsDirectory)
        let names = try FileManager.default
            .contentsOfDirectory(atPath: topicsURL.path)
            .filter { $0.hasSuffix(".md") }
            .sorted()

        guard !names.isEmpty else {
            throw DocsError.noTopicFiles(topicsURL.path)
        }

        let topics = try names.map { name in
            Doc(name: "\(topicsDirectory)/\(name)",
                text: try String(contentsOf: topicsURL.appendingPathComponent(name), encoding: .utf8))
        }
        return [index] + topics
    }

    enum DocsError: Error, CustomStringConvertible {
        case noTopicFiles(String)

        var description: String {
            switch self {
            case .noTopicFiles(let path):
                return """
                    No topic files under \(path). Every guard over what the agent instructions say \
                    reads AGENTS.md plus the bodies moved out of it by #3640, and a corpus of one \
                    file is a guard covering a fraction of its subject while reporting green.
                    """
            }
        }
    }
}
