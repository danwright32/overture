import Testing
import Foundation

// #524: the temp-file-at-explicit-mode-plus-atomic-rename technique GmailCredentials.saveTokens
// established for #486, now shared so any other write of security-sensitive data (starting with
// DebugSeed's token-file copy) gets the same guarantee: the destination is never observable wider
// than the requested mode, and a genuine failure is reported instead of silently swallowed.
@Suite("Secure file write (#524)")
struct SecureFileWriteTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("secure-file-write-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func createsTheFileAtTheRequestedMode() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.json")

        #expect(SecureFileWrite.writeOwnerOnly(Data("hello".utf8), to: url) == true)

        let perms = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello")
    }

    @Test func honorsACustomMode() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.json")

        #expect(SecureFileWrite.writeOwnerOnly(Data("hello".utf8), to: url, mode: 0o644) == true)

        let perms = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o644)
    }

    @Test func replacesAnExistingDestinationRegardlessOfItsPriorPermissions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.json")
        try "stale".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        #expect(SecureFileWrite.writeOwnerOnly(Data("fresh".utf8), to: url) == true)

        #expect(try String(contentsOf: url, encoding: .utf8) == "fresh")
        let perms = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }

    @Test func createsMissingIntermediateDirectories() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/deeper/secret.json")

        #expect(SecureFileWrite.writeOwnerOnly(Data("hello".utf8), to: url) == true)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // A genuine, deterministic filesystem failure (directory not writable) must be reported, not
    // swallowed, mirroring GmailCredentials' own saveTokensReturnsFalseWhenTheDestinationDirectoryIsNotWritable.
    @Test func returnsFalseWhenTheDestinationDirectoryIsNotWritable() throws {
        let dir = try tempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let url = dir.appendingPathComponent("secret.json")

        #expect(SecureFileWrite.writeOwnerOnly(Data("hello".utf8), to: url) == false)
    }

    @Test func leavesNoTempFileBehindOnSuccess() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.json")

        _ = SecureFileWrite.writeOwnerOnly(Data("hello".utf8), to: url)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "secret.json" }
        #expect(leftovers.isEmpty)
    }
}
