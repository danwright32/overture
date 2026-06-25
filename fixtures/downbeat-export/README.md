# Downbeat export contract fixtures (#113)

These JSON files are the single source of truth for the Downbeat → Overture export wire
format (`danwright32/downbeat .../OvertureExport/CONTRACT.md`). They are decoded by BOTH
readers, each asserting the same logical result:

- TypeScript scout: `src/lib/downbeatExportContract.test.ts` (via `parseDownbeatExport`)
- Swift app: `mac/OvertureTests/DownbeatExportContractTests.swift` (via `DownbeatBridge.decode`)

When the export format changes, update these fixtures and the CONTRACT.md together; a reader
that hasn't caught up then fails its test instead of silently treating clients as cold in
production (the #109 regression). `v2.json` exercises the edge cases: a minimal client with
omitted optionals, and an ad-hoc booking with an omitted `venueId`.
