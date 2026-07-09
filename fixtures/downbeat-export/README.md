# Downbeat export contract fixtures (#113)

These JSON files are the single source of truth for the Downbeat → Overture export wire
format (`danwright32/downbeat .../OvertureExport/CONTRACT.md`), decoded by the app's reader:

- Swift app: `mac/OvertureTests/DownbeatExportContractTests.swift` (via `DownbeatBridge.decode`)

This used to also be decoded by a TypeScript mirror (`src/lib/downbeatExportContract.test.ts` via
`parseDownbeatExport`); #493 retired it once it was confirmed unused (the app scouts natively),
so the app is now the only reader. When the export format changes, update these fixtures and the
CONTRACT.md together; a reader that hasn't caught up then fails its test instead of silently
treating clients as cold in production (the #109 regression). `v2.json` exercises the edge cases:
a minimal client with omitted optionals, and an ad-hoc booking with an omitted `venueId`.
