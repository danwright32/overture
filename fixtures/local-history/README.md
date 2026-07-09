# Local history contract fixtures (#166)

`v1.json` is the single source of truth for the local booking-history handoff
(`~/Library/Application Support/Overture/overture-history.json`): the one-time legacy import plus
Overture's own derived activity that feeds the native scout's prior-relationship signal.

The TS importer (`scripts/import-history.ts`) writes it; the app reads it:

- Swift app: `mac/OvertureTests/LocalHistoryContractTests.swift` (via `[HistoryRecord]`).

This used to also be a two-reader contract: a TypeScript mirror (`src/lib/localHistoryContract.test.ts`
via `parseLocalHistory`) bridged the file's camelCase `{ groupName, status }` to the matcher's
snake_case `{ group_name, status }`, guarding the #104 surface where a format change either reader
hadn't caught up to would silently read undefined and treat every org as cold in production (the
#109 class). #493 retired that TypeScript reader once it was confirmed unused (the app scouts
natively); the app is now the only reader. The fixture exercises the status vocabulary the ranker
understands (`booked`, `dnc`, `lost_soft`, `warm`, `contacted`) plus a `null` status (an unrecognized
status reads as cold). `status` may be absent/null; the reader must tolerate it.
