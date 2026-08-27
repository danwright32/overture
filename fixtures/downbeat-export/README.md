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

`future-version-with-unknown-keys.json` is NOT a copy of any real Downbeat version and deliberately
does not carry one in its name. It stands for whatever the next bump turns out to be: a version
number well above anything shipped, plus unknown keys at the top level, on a client, on a venue and
on a booking. It exists because the gate used to be the exact set `[1, 2]`, so the next bump would
have thrown, and `DownbeatBridge.loadWithHealth` answers a throw with empty clients, empty bookings
and empty blockedDates (#3193). Nothing here has seen the real next version, so this file asserts
only what the contract promises (the format is additive, and unknown keys are ignored) rather than
claiming to be a copy of a shape nobody has measured.
