import Testing
import Foundation

// #2681 and #2677, the corpus both of them said they needed before anything could be built.
//
// `ListingOrganiser.producerNamed` reads a producing credit out of a show's own listing PROSE. Two open
// questions sit on it and neither could be answered from the one example each issue had in hand:
//
//   #2681: the stored value keeps whatever the page put between the credit and the name, so
//   "Produced and directed by Showpeople Resident Artist Colby Thompson" is stored whole and is a worse
//   search string than the name alone would be. Can a leading role phrase be recognised safely?
//
//   #2677: two credit shapes in the VenueTix feed are refused (`From producers X and Y`,
//   `From The Producers of Z`) and the connectors that would read them have never been measured against
//   listing PROSE, where a performer's biography routinely mentions producers.
//
// This reads the real listings out of the archived work-lists, runs the app's OWN rule over them, and
// prints what it extracts. A corpus, not a gate: what it exists to do is put real strings in front of
// whoever picks either issue up, so a rule is calibrated against what listings actually say rather than
// against the one line somebody quoted (L48, L104).
//
// Aggregates and EXTRACTED CREDITS only, never a whole listing: the archives hold real pages about real
// people and this repository is public (L155, L222). A credit is a company or a producer's billing line,
// which is the same class of value `fixtures/venuetix-supertitles/` already carries in the open.
@Suite("What the producer rule reads out of real listing prose (#2681, #2677)")
struct ListingCreditCorpusTests {

    private static var handoff: URL {
        StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private struct Listing {
        let title: String
        let venue: String?
        let text: String
    }

    private static func archivedListings() -> [Listing] {
        var seen: Set<String> = []
        var out: [Listing] = []
        for slot in RunSlot.allCases {
            let dir = PrepRunArchive.archivesDirectory(slot: slot, handoffDirectory: handoff)
            let stamps = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter(PrepRunArchive.isArchivedRunFolder).sorted()
            for stamp in stamps {
                let queue = dir.appendingPathComponent(stamp, isDirectory: true)
                    .appendingPathComponent(PrepRunArchive.queueFilename(for: slot))
                guard let decoded = HandoffFile.read(at: queue,
                                                     decode: { try JSONDecoder().decode(PrepQueue.self, from: $0) }).value
                else { continue }
                for item in decoded.items {
                    guard let listing = item.showListing, let text = listing.text, !text.isEmpty,
                          !seen.contains(item.naturalKey) else { continue }
                    seen.insert(item.naturalKey)
                    out.append(Listing(title: item.groupName, venue: item.venue, text: text))
                }
            }
        }
        return out
    }

    // Whether there are archived RUNS to look in, asked independently of the walk the test performs.
    //
    // It used to be `!archivedListings().isEmpty`, which is the same lookup the test itself runs, so the
    // condition and the floor could only ever confirm each other (L70): break the read and the test was
    // SKIPPED rather than failed, and a skipped test reads as green. Found by mutation, which reported
    // SURVIVED on a queue filename pointed at nothing.
    private static var anyArchivedRuns: Bool {
        RunSlot.allCases.contains { slot in
            let dir = PrepRunArchive.archivesDirectory(slot: slot, handoffDirectory: handoff)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.contains(where: PrepRunArchive.isArchivedRunFolder)
        }
    }

    // The words a credit uses. Kept here rather than derived from `ProducerShapedName`, deliberately and
    // for once: this is asking what listings SAY, and deriving the question from the rule would only ever
    // find what the rule already reads, which is the opposite of a corpus (L70).
    private static let creditWords = ["produced by", "producers", "directed by", "created by",
                                      "curated by", "presented by", "music direction by"]

    @Test(.enabled(if: anyArchivedRuns, "no archived runs on this machine"))
    func theCorpusSaysWhatTheRuleReadsAndWhatItLeaves() {
        let listings = Self.archivedListings()
        // Archived runs exist, so reading no listing at all is a broken walk rather than a history of
        // runs whose shows published no page (L98, L11).
        #expect(!listings.isEmpty, Comment(rawValue:
            "archived runs exist and not one listing could be read from them, so nothing below measured "
            + "anything"))
        guard !listings.isEmpty else { return }

        var read: [String] = []
        var unread: [String] = []
        for listing in listings {
            let named = ListingOrganiser.producerNamed(inListingText: listing.text,
                                                       showTitle: listing.title, venue: listing.venue)
            if let named { read.append(named) }
            let lower = listing.text.lowercased()
            if named == nil {
                // #2677's half: the credit phrases on a page the rule reads NOTHING from. A bounded
                // window around the phrase rather than the listing, because the listing is a whole page
                // about real people and the phrase is the only part either issue is about.
                for word in Self.creditWords where lower.contains(word) {
                    guard let at = lower.range(of: word) else { continue }
                    let end = lower.index(at.upperBound, offsetBy: 60, limitedBy: lower.endIndex)
                        ?? lower.endIndex
                    unread.append(String(listing.text[at.lowerBound..<end])
                        .replacingOccurrences(of: "\n", with: " "))
                }
            }
        }

        // #2681's question, asked of the values the rule really stores: how many carry more than a name.
        // Judged by LENGTH IN WORDS rather than by trying to spot a role, because spotting one is the
        // very thing the issue says is hard and a reading that guessed would be reporting its own guess.
        let long = read.filter { $0.split(whereSeparator: \.isWhitespace).count > 3 }.sorted()

        print("listing-credit corpus: \(listings.count) archived listings, "
              + "\(read.count) carry a credit the rule reads, "
              + "\(unread.count) credit phrases on pages it reads nothing from, "
              + "\(long.count) of the read values run to more than three words")
        for value in read.sorted() { print("  credit read: \(value)") }
        for value in long { print("  MORE THAN A NAME: \(value)") }
        for value in Set(unread).sorted() { print("  NOT READ: \(value)") }

        // The corpus was really walked. Without this every number above could be zero for the emptiest
        // possible reason and the line would read as a rule that handles everything (L182, L98).
        #expect(!read.isEmpty, "the rule read no credit out of any archived listing at all")
    }
}
