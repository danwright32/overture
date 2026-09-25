import Foundation
import SwiftData
import Testing

// #3558: nothing stopped a persisted model losing a stored property.
//
// This app has never made a subtractive schema change. It carries no MigrationPlan or VersionedSchema
// (see AppSchema), so every column it has ever added still sits in Dan's live store, and the launch
// backup is the only net under it. Dropping a stored property is the first subtractive migration, and
// the rule written in three places (AppSchema, and the RETAINED STORAGE comments on Prospect and
// Recipient) is that it gets its own change with a rehearsal against a store clone first.
//
// That rule was enforced by nothing. On 2026-09-05 #3549 deleted `Recipient.overrideBody`, a persisted
// property, and pushed it with a full green suite. It was caught only because somebody happened to read
// one of those comments while sweeping an unrelated issue.
//
// So the stored properties are DERIVED, from the same `Schema` the app opens its store with, and held
// against `fixtures/stored-properties.txt`. Derived from the Schema rather than by reading the source
// text, because the Schema is what SwiftData actually persists: a `@Transient` or computed property is
// correctly absent from it, and a text scan would have to re-implement the macro's rules to agree.
//
// The list is a RATCHET in one direction. It may grow freely, since additive is the safe direction, and
// a new property must be added to it so that its own later removal is caught too. It may shrink only by
// a deliberate edit in the same change as the removal, which is where the rehearsal against a store
// clone gets stated.
@Suite("Every stored property the live store holds is still declared (#3558)")
struct StoredPropertyRatchetTests {

    static let listPath = "fixtures/stored-properties.txt"

    // "Entity.property" for every attribute and relationship of every model in AppSchema.
    static func derived() -> Set<String> {
        var out: Set<String> = []
        for entity in AppSchema.schema.entities {
            for a in entity.attributes { out.insert("\(entity.name).\(a.name)") }
            for r in entity.relationships { out.insert("\(entity.name).\(r.name)") }
        }
        return out
    }

    static func recorded() throws -> Set<String> {
        let url = RepoRoot.url.appendingPathComponent(listPath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    // A derivation that found nothing makes both checks below pass over everything they exist to check
    // (L98), so it must reach every model in AppSchema, and every one of them must have properties.
    @Test func theDerivationReachesEveryModel() {
        let entities = AppSchema.schema.entities
        #expect(entities.count == AppSchema.models.count, "The schema derived \(entities.count) entities from \(AppSchema.models.count) models in AppSchema, so the stored property list is being judged against part of the store.")
        let empty = entities.filter { $0.attributes.isEmpty && $0.relationships.isEmpty }.map(\.name).sorted()
        #expect(empty.isEmpty, "These entities derived no stored properties at all: \(empty.joined(separator: ", ")). That is a broken derivation, not an empty model.")
    }

    @Test func noStoredPropertyHasBeenRemoved() throws {
        let present = Self.derived()
        let entities = Set(AppSchema.schema.entities.map(\.name))
        let gone = try Self.recorded().subtracting(present).sorted()
        let lines = gone.map { column -> String in
            let entity = String(column.split(separator: ".").first ?? "")
            return entities.contains(entity) ? "  \(column)" : "  \(column)   (the whole \(entity) model is gone)"
        }
        #expect(gone.isEmpty, """
            \(gone.count) stored propert\(gone.count == 1 ? "y" : "ies") recorded in \(Self.listPath) \
            no longer exist\(gone.count == 1 ? "s" : "") on any model in AppSchema:

            \(lines.joined(separator: "\n"))

            Each one is a column in Dan's live store. Removing it is this app's first SUBTRACTIVE \
            migration, and there is no MigrationPlan or VersionedSchema, so the launch backup is the \
            only net. If this was not deliberate, put the property back: a column read and written by \
            nothing is kept as RETAINED STORAGE (see Recipient.overrideBody). If it is deliberate, it \
            gets its own change with a rehearsal against a clone of the live store (see \
            InquiryMigrationDryRunTests), and that change deletes these lines from \(Self.listPath) \
            and states the rehearsal. A rename is a removal too, unless it carries \
            @Attribute(originalName:).
            """)
    }

    // Keeps the list complete, so a property added today is protected from being removed tomorrow.
    @Test func everyStoredPropertyIsRecorded() throws {
        let fresh = Self.derived().subtracting(try Self.recorded()).sorted()
        #expect(fresh.isEmpty, """
            \(fresh.count) stored propert\(fresh.count == 1 ? "y is" : "ies are") not yet recorded in \
            \(Self.listPath). Adding a column is the safe direction, so add these lines, in sorted order:

            \(fresh.joined(separator: "\n"))
            """)
    }
}
