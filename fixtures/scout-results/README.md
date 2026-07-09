# Scout results contract fixtures (#157)

These JSON files were the single source of truth for the scout results handoff
(`~/Library/Application Support/Overture/overture-results.json`), mirroring
`fixtures/downbeat-export` + the #113 guard. #493 retired the TypeScript writer
(`resultsContract.test.ts` / `buildResultsFile`) once it was confirmed to be a reference mirror
only, the native scout has always upserted straight into SwiftData, never through this file. Only
the reader side remains:

- Swift reader: `mac/OvertureTests/ResultsContractTests.swift` (via `ResultsFileDecoder.decode`),
  which stays in place for a manually-produced file, though nothing writes one anymore.

`v2.json` exercises the live format and its edge cases: a collapsed multi-night run (opening night
keeps both nights' `runSourceUrls` and the `runEndDate`), a separate later run of the same group
flagged `partOfRelatedRun`, and an undated prospect that sorts last with absent optionals as `null`.

`v1.json` is the pre-#132 shape (run-collapse keys and optional fields omitted). The current writer
no longer emits v1, so only the Swift reader decodes it, asserting the tolerant version gate and the
defaults (`partOfRelatedRun` false, `runSourceUrls` empty) the importer relies on.
