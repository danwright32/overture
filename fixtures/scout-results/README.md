# Scout results contract fixtures (#157)

These JSON files are the single source of truth for the scout results handoff
(`~/Library/Application Support/Overture/overture-results.json`). Both sides assert the same
logical shape, mirroring `fixtures/downbeat-export` + the #113 guard:

- TypeScript writer: `src/lib/resultsContract.test.ts` (via `buildResultsFile`). `v2.json` is the
  EXACT output the writer produces from a fixed set of sample rows, so a change to the wire shape
  fails the test instead of silently breaking ingestion (the #109 regression).
- Swift reader: `mac/OvertureTests/ResultsContractTests.swift` (via `ResultsFileDecoder.decode`).

`v2.json` exercises the live format and its edge cases: a collapsed multi-night run (opening night
keeps both nights' `runSourceUrls` and the `runEndDate`), a separate later run of the same group
flagged `partOfRelatedRun`, and an undated prospect that sorts last with absent optionals as `null`.

`v1.json` is the pre-#132 shape (run-collapse keys and optional fields omitted). The current writer
no longer emits v1, so only the Swift reader decodes it, asserting the tolerant version gate and the
defaults (`partOfRelatedRun` false, `runSourceUrls` empty) the importer relies on.
