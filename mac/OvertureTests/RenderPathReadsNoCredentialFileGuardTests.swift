import Testing
import Foundation

// #1770: the queue's render path must ask the filesystem nothing.
//
// GmailConnectionTests pins that the cache CAN answer without a disk read. That is worthless on its own
// if a view still calls the disk-reading spelling instead, which is exactly the shape that shipped: a
// per-card `GmailAuthManager.shared.isConnected` inside a SwiftUI view body, re-read for every visible
// card on every scroll frame. Whether a view reads a file cannot be observed from the value it produces
// (both spellings answer the same question correctly), so there is no runtime assertion to make here.
// What rots is the SPELLING at the call site, and that is what this pins, the same way
// QueueRenderDataGuardTests pins #1121's shape.
@Suite("No render path re-reads the Gmail token file (#1770)")
struct RenderPathReadsNoCredentialFileGuardTests {
    // Every spelling that ends in a Data(contentsOf:) against the token file.
    private let diskReadingSpellings = [
        "GmailAuthManager.shared.isConnected",
        "GmailCredentials.isConnected",
        "GmailCredentials.loadTokens",
    ]

    private let renderPathFiles = [
        "Overture/UI/ProspectRowFactory.swift",
        "Overture/UI/QueueView.swift",
        "Overture/UI/ArchiveView.swift",
        "Overture/UI/FollowUpsView.swift",
    ]

    @Test func noViewOnTheRenderPathReadsTheTokenFile() {
        for path in renderPathFiles {
            let source = SourceGuardHelper.source(path)
            #expect(!source.isEmpty, "expected to read \(path)")
            for spelling in diskReadingSpellings {
                #expect(!source.contains(spelling),
                        "\(path) reads the Gmail token file from a render path via \(spelling). Read GmailConnection.shared.isConnected instead (#1770)")
            }
        }
    }

    // The factory builds one card. It must be HANDED the answer rather than sourcing one, so that no
    // future call site can reintroduce a per-card lookup of any kind, cached or not.
    @Test func theRowFactoryTakesTheConnectedFlagAsAParameter() {
        let source = SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift")
        #expect(source.contains("gmailConnected: Bool"))
    }
}
