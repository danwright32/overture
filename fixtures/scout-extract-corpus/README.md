# Scout-extract location corpus (#988)

A checked-in corpus that measures whether the location rules in
`docs/scout-extract-runbook.md` (§3a and §3) are still being followed. Read by
`src/lib/scoutExtractLocationGuard.test.ts`.

Not a `docs/contracts.md` handoff contract: nothing writes or reads this file at runtime
(same footing as `fixtures/discipline-corpus/`).

## Why this exists

The scout-extract run is a Claude Code workflow, not code, so the runbook plus
`fixtures/scout-extract/` is its only spec and it has no automated test of its own. #985
made the runbook substantially more load-bearing: §3a now instructs the run to report
`location` VERBATIM, exactly as the page wrote it, never tidied, expanded, abbreviated, or
guessed, and #970's entire geographic gate depends on that instruction being followed. If
the run quietly starts tidying `Baltimore, Maryland` into `Baltimore, MD`, or infers a city
from an org's name, nothing downstream catches it, and a confident wrong place is the one
failure mode that can HIDE a real show from Dan, which the runbook says is worse than
reporting nothing.

An instruction nobody measures is a bet (the lesson of #970, see #979 and #983: the first
plan's parser fired on zero rows of the real target and looked fine until a page was actually
fetched). #591 tracks the same exposure for the prep-runbook. This corpus closes it for the
scout-extract runbook's location rules.

## How it is checked

The real agent is run against the gold corpus only periodically, because it costs a real run.
What runs on every PR is cheap and deterministic: the runbook's checkable rules are encoded as
pure functions in `src/lib/scoutExtractLocationGuard.ts`, and the test drives this corpus both
ways.

- `location-cases.json` is the gold corpus: the runbook's own worked input/output pairs. Each
  case is a page snippet, plus the `venue` and `location` a correct run reports. The guard must
  find NO violation in any of them. This is also the natural seed for the periodic real-agent
  run: feed the agent each `pageText`, diff its extraction against the case.
- `violation-cases.json` is the failure corpus: the exact forbidden extractions the runbook
  calls out (a state name shortened to its abbreviation, a country appended to a bare city, a
  city guessed from the org name, a place string copied into `venue`). Each carries the
  `expectViolation` kind the guard must raise. This is the permanent "seen it go red": if a
  checker silently stops firing, one of these cases turns green and the suite fails.

The two rules the guard encodes:

- **3a, location is verbatim.** The reported `location` must appear on the page exactly as
  written. A location that is not a verbatim slice of the page was either edited or invented;
  both are caught, because neither survives as a substring of the page's own text. A null
  location is always allowed (the page simply did not say, which is common and not a failure).
- **3, a place is not a room.** A place-only string (`Baltimore, Maryland`, `Harrogate, UK`)
  belongs in `location`, never `venue`. A named place with its own proper name (`Sakura Park`,
  #1057) IS a venue, even when the location repeats it verbatim. The guard's
  `looksLikeBareLocation` test is asserted in both directions so the bar is not vacuous: every
  named venue in the runbook's table must pass as a venue, and every bare place must be flagged.

## Provenance

Every case is drawn from the runbook's own §3a and §3 tables and the real failures they
document (the first venue-less scout that returned `venue: "Baltimore, Maryland"` and
`venue: "Harrogate, UK"`, and the `smokeringquartet.com/gigs` rows that publish a city and no
venue). The page snippets are short representative renderings that carry the same verbatim
location string the real page did; nothing here is a fabricated place. One address uses the
plain spelling `Thorwaldsenstrasse` in place of the page's ess-zed so the fixture stays ASCII.
