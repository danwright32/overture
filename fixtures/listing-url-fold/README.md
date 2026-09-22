# Listing URL fold fixture (#4116)

`ListingURL.fold` is the one place a listing address is folded before two of them are compared for
identity. Two of `ScoutService`'s four upsert arms read it (`matchByAnyRunURL` and
`matchByStableSource`), so what it does decides whether an arriving listing joins a stored row or
mints a second card.

`scripts/derive-showlink-shape.sh` has to answer the same question about the same addresses, in
Python, against a clone of the live store: its ambiguity report (#4078) counts how many titles each
URL carries, and that count is the reachable population for #4098. A second implementation of the
fold is the thing this repository already pays for elsewhere (L26), so both read this fixture rather
than each other.

`v1.json` holds `fold` cases: an input address, the expected folded form, and WHY that case is here.
The `why` is load bearing. Three of the cases record a rule deliberately NOT adopted (host case,
path case, scheme), each measured on 2026-09-21 to join zero further pairs on the live store, so a
later pass that widens the fold has to argue with a case rather than with an absence.

Read by `mac/OvertureTests/TrailingSlashListingURLTests.swift` (`ListingURLFoldContractTests`) and by
`scripts/derive-showlink-shape.test.sh`.
