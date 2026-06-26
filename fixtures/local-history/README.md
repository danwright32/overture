# Local history contract fixtures (#166)

`v1.json` is the single source of truth for the local booking-history handoff
(`~/Library/Application Support/Overture/overture-history.json`): the one-time legacy import plus
Overture's own derived activity that feeds the scout's prior-relationship signal.

This is a two-reader contract. The TS importer (`scripts/import-history.ts`) writes it; both readers
decode the SAME committed fixture and assert the same logical result, mirroring the #113 Downbeat
guard:

- TS scout: `src/lib/localHistoryContract.test.ts` (via `parseLocalHistory`), which bridges the
  file's camelCase `{ groupName, status }` to the matcher's snake_case `{ group_name, status }`.
- Swift app: `mac/OvertureTests/LocalHistoryContractTests.swift` (via `[HistoryRecord]`).

Why it matters: this is the #104 surface. The file is camelCase but the TS matcher needs snake_case,
so a format change a reader hasn't caught up to silently reads undefined and treats every org as cold
in production (the #109 class). The fixture exercises the status vocabulary the ranker understands
(`booked`, `dnc`, `lost_soft`, `warm`, `contacted`) plus a `null` status (an unrecognized status
reads as cold). `status` may be absent/null; the readers must tolerate it.
