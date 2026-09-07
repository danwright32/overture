# The app's words, and the drafting rules

The copy inventory and its cold read, the outbound email copy, the brand voice skill, the prep
eval harness, and two writing rules the style gate cannot enforce on its own.

Split out of `AGENTS.md` in #3640, which was over the character limit for a file loaded
into every session. The text below is unchanged: these are dated measurements, and
rewriting one destroys the record. `AGENTS.md` names each rule and points here.

- **A store-wide COUNT quoted in prose either carries its date or is not quoted at all (#3487).** Two
  readings were quoted across the tree as if current: `724` (measured 2026-08-01) in roughly 20 places
  and `702` (2026-07-29) in about 8. The store held 1,142 rows when this was written, so the
  explanations were wrong by more than half, and a figure with a date on it reads as MORE trustworthy
  the older it gets (L316, L210).
  The distinction that decides what to do with one, applied to all 28: a figure standing in for "the
  whole store" (`re-derives all 724 prospects`) says nothing the sentence does not already say and rots,
  so it is written as `every prospect in the store` and can never be wrong again. A figure that IS a
  dated measurement (`0 of 724 shows inheriting on 2026-07-29`) is evidence and stays exactly as it is,
  because rewriting it would destroy the record.
  #3426's `LIVE-SHAPE` tag and `scripts/check-fixture-corpus-drift.sh` cover the DECLARATIONS, the
  numbers a program can compare. A sentence cannot carry that tag, so this half is a convention rather
  than a check, and it is written here rather than left as a habit. The TAGGED figures, the ones
  carrying a `verified=` stamp that `scripts/check-live-store-claims.sh` reads, are a third case again:
  they carry a date AND a re-derivable measure, and re-verifying rather than restamping them is #2517.
  (The tag itself is deliberately not spelled out in this paragraph. That scanner reads every tracked
  Markdown file, so writing it here makes this sentence a malformed claim and fails the check, which is
  the scanner working: it cannot tell a line USING the tag from a line ABOUT it, exactly as the style
  gate cannot for an em dash.)

- **Quoting a character the style gate forbids: write it as an escape, never override the gate.**
  The pre-push style gate blocks any new line holding an em dash, en dash or emoji, and it cannot
  tell a line that USES one from a line that must QUOTE one, which is the gate working correctly.
  The answer is to build the character rather than type it, so the file holds no literal one:
  `mac/scripts/lib/suite-stats.test.sh` is the worked example (#2193), where a fixture legitimately
  needed the marks Swift Testing prints and builds them from their UTF-8 bytes with `printf`. In
  Swift the same trick is a unicode escape (`\u{2014}`). `SKIP_STYLE_CHECK=1` is visible and
  tempting and skips past a clean solution, so it is the wrong tool here (#2312).

- Changing what the app SAYS: `docs/copy-inventory.md` is every sentence Overture can say to Dan
  (#915), generated from the source and checked in. The test suite fails when it is stale, so a PR
  that changes the app's wording shows that change in the diff, in the words Dan will read rather
  than as a line of Swift. Since #1994 a failing run **writes nothing**: it names the sentences that
  moved and stops, because a run that was not asked to change the repo must not change it. (It used
  to rewrite the file in place, and on 2026-08-02 that put a `fatalError` string, added only to break
  the app on purpose, into the checked-in list of what Overture says to Dan, where a `git add -A`
  would have shipped it.) When the difference IS your copy change, regenerate and commit it:

  ```
  TEST_RUNNER_REGENERATE_COPY_INVENTORY=1 mac/scripts/run-tests-locked.sh
  ```

  The `TEST_RUNNER_` prefix is load-bearing, not decoration: xcodebuild does not pass its own
  environment to the test process, it forwards only variables with that prefix and strips it. The
  bare name is silently ignored. Copy that is NOT the app's own voice (an outbound email body, an RFC822 header,
  AppleScript, the draft lint's search terms) is marked at the source with
  `// copy-inventory:ignore-start  <why>`, and every such region is listed in the inventory itself.
  **The outbound email half of that has its own document and its own cold read (#2650):
  `docs/outbound-copy.md`**, generated the same way and kept fresh by the same suite, from the ignore
  regions tagged `outbound-email:`. It exists because an exclusion that is CORRECT still leaves its
  content with no reviewer unless one is named (L129): the inventory is rightly the app's voice to Dan,
  which left the sentences going to strangers under his name as the only copy in the product nobody read
  cold. #2643 is the proof, a closing note telling people who had never replied that it was good to be in
  touch, which survived a rewrite of the sentence beside it three days earlier. Read its diff in the same
  pass as the inventory's, and ask the question that list exists for, which is NOT the inventory's
  question: what state is this sentence ONLY ever sent in, and is every clause true of that state? A
  region that reads like outbound email and carries no tag fails `OutboundCopyTests`, so a new one cannot
  quietly arrive without a reader.
  Before opening a PR that adds or changes any of these sentences, read the new and changed ones
  COLD (#843/#844): open `git diff docs/copy-inventory.md`, read each added or reworded line in the
  order a person meets it on screen (the row title before its subtitle, the section heading before
  its body, the pill name before its detail, the concept summary before the live line shown beside
  it), with no memory of why the code produces it, and ask of each: does this tell Dan anything the
  line next to it did not? If not, cut it, or show the second line only in the edge case where the
  two genuinely differ. The whole class of defect (#840, #841, the third in #840's comment, and the
  nine #843 fixed) is invisible from inside the code and obvious the instant a person reads the
  screen, and no test can catch any of it; this cold read is the only thing that does, so it is a
  required step, not a good intention. A distinction that is real in the code ("checked" versus
  "read", #803) still collapses to the same sentence twice in the common case, which is exactly what
  the read has to catch.
  Read a section in EVERY BRANCH it can render, not just the populated one (#1547). The coverage box's
  explaining sentence was correct, tested and inside the has-gaps branch, so the state Dan was actually
  in (no gaps, some clients set aside) rendered the heading over a bare count and nothing else, reading
  as the exact opposite of what it meant. He asked what the section was for. A cold read of the diff
  cannot catch that, because the sentence it would have him read is the one that never appeared: the
  question to ask of each conditional is what this surface says when the list is EMPTY, when it holds
  one, and when the branch that carries the explanation is the one not taken.
  **Since #2945 that document has a second half, keyed to where a sentence RENDERS rather than where its
  words are written.** Both generated documents key a sentence to the file holding its LITERAL text, so
  moving an EXISTING sentence onto a BRAND NEW surface produced no diff at all and therefore got no cold
  read, which is exactly when placement most needs reading. Measured while building #2816: "Source
  listing" and "Venue calendar" arrived on three rows they had never appeared on and both documents came
  out byte for byte identical. `copy-surfaces.md` now also lists, per file, the copy CONSTANTS that file
  names, so a view that renders words it does not contain shows up in the diff. What it still cannot see
  is copy that reaches a view as a VALUE rather than as a symbol, which is the #2816 case itself: the
  sentence is returned by a private function, put on a struct and handed to the row that draws it, so no
  file outside the declaring one names anything a source-text reader can match. That gap is #3118 rather
  than something to discover by trusting the section.
  Read the OTHER generated diff in the same pass: `docs/copy-surfaces.md` (#2210) says which surfaces
  each file renders into, so the cold read answers where a new sentence LANDS as well as what it says.
  A message in a toolbar item, a menu bar item, an OS alert or an info block can be correct, tested,
  and still fail to do its job (the platform relocates or covers it, or it arrives somewhere Dan
  cannot act on it), and that report names those four surfaces and why each one is a risk. Three of
  the eight defects found on 2026-08-06 were exactly that shape and none was visible in the sentence
  alone.

- Changing the AI drafting instructions: those rules live in two places that must stay in sync,
  `docs/prep-runbook.md` §2 inside this repo and the `dan-wright-brand-voice` skill at
  `~/.claude/skills/dan-wright-brand-voice/` (which is NOT tracked by this repo, and is the
  authoritative source, "the skill always wins"). `scripts/check-brand-voice-drift.sh` (#731) warns
  when the two drift apart on the concrete facts they both state (the citable credentials, marquee
  venues, portfolio link, the four opener shapes, the soft close). It rides along in
  `scripts/test-all.sh`, and skips cleanly on any machine without the skill installed, so edit a
  drafting rule in one place and a local pre-push run flags the other side going stale.

- Regression harness for the runbook's JUDGMENT (#591). The runbook is a prompt, not code, so a rule
  it encodes (never the host venue, never a press inbox, both named performers, strict confidence) can
  be silently broken by an unrelated edit. Two layers guard it. The ALWAYS-ON free layer runs on every
  `pnpm test`: `src/lib/prepRunbookRules.test.ts` asserts each guarded rule stays in the runbook text,
  and `src/lib/prepEval.test.ts` scores recorded outputs against `fixtures/prep-eval/` expectations. The
  OPT-IN real-AI layer, `scripts/eval-prep-runbook.sh --yes`, runs the CURRENT runbook against those
  fixtures through the same headless `claude -p` mechanism as `prep-run.sh` and scores each real output
  with the SAME engine (`src/lib/prepEval.ts`). It SPENDS TOKENS and is wired into no CI job: run it by
  hand before shipping a runbook edit. See `fixtures/prep-eval/README.md`.
  Remembering to run it was the whole mechanism, and it did not hold: the harness could not start at all
  from 2026-07-28 to 2026-07-31 (#1862) with nobody noticing, and two runbook edits (#1856, #1817) shipped
  before it had scored either. So `scripts/check-prep-eval-freshness.sh` (#1867) rides along in
  `scripts/test-all.sh` and WARNS when `docs/prep-runbook.md` has changed since the eval last completed.
  It never blocks (the eval spends tokens, so a gate would either be overridden every time or spend money
  by itself), it keeps "never run here" and "stale since a date" as separate messages, and it skips
  cleanly where the eval could not run anyway (no `claude` CLI, so CI and a fresh clone). What it reads is
  `.overture-eval-last-run`, written by the eval only AFTER its last fixture is scored and naming the
  runbook's content hash rather than any mtime: the dated `.overture-eval-runs/` directory is created
  before the first AI call, so a run that died there would leave one indistinguishable from a finished
  run's, and a clone rewrites every mtime.
