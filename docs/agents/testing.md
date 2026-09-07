# Running and reading the Swift and shell suites

How to run the suites, how to read what they report, and how to prove a guard works.
Read the whole entry before trusting a run's verdict: most of what is written here exists
because a run once reported success while executing nothing.

Split out of `AGENTS.md` in #3640, which was over the character limit for a file loaded
into every session. The text below is unchanged: these are dated measurements, and
rewriting one destroys the record. `AGENTS.md` names each rule and points here.

- **Waiting for something in a Swift test: `waitUntil` in `mac/TestSupport/WaitUntil.swift`, and it
  SUSPENDS rather than spins (#2576, #3277).** It is the one way this suite waits, and it carries a
  deadline, because the obvious spelling (`while !condition { await Task.yield() }`) cannot fail: it can
  only hang, and a hang takes the whole suite plus the machine-wide xcodebuild lock with it while being
  indistinguishable from a slow machine (L110).
  What #3277 changed is the poll. It used `Task.yield()`, which reschedules the waiter immediately, so
  the loop ran as fast as a core allowed and one waiter burned that core for the length of the wait:
  measured 2026-08-30, 12,322 polls in 200 milliseconds, on an idle machine, from a single test. Serially
  that is invisible, because one spinner on an otherwise idle machine always gets its answer. Under
  `-parallel-testing-enabled YES -parallel-testing-worker-count 12` there are twelve worker PROCESSES,
  each with its own cooperative pool sized to the whole machine, and the spinners starve the work they
  are waiting for (L241). Two of five consecutive full parallel runs went red and every failure in both
  was a test that waits; the clearest was `LoopbackListener.start(timeout: 5)` reporting
  `failed (45.464 seconds)`, which is a five second deadline that took forty five seconds to be noticed
  rather than a bind that was refused.
  `WaitUntilTests` guards it by POLL COUNT rather than by duration, because a duration compared against
  a fixed number measures what else the machine is running (L224): a suspending wait can only poll about
  as often as its sleep allows however fast the machine, while a spinner polls as fast as a core will
  let it. It also guards the CLASS, flagging any `Task.yield()` whose nearest enclosing loop is a
  `while`; a bounded `for _ in 0..<8 { await Task.yield() }` is deliberately left alone, since it returns
  the thread after a fixed number of turns, which is what `SharedStateTestLockTests` uses.
  The timeout message no longer says "This is a FAILURE, not a slow machine". That was true serially and
  false under parallel, in the wording most likely to stop somebody looking further (L11).

- Mac app: `cd mac && xcodegen generate`, then `./scripts/run-tests-locked.sh` (wraps
  `xcodebuild -scheme Overture -destination 'platform=macOS' test` in a lock so it can't
  collide with another test run on this Mac; use it instead of raw `xcodebuild test`). A
  scoped `-only-testing:OvertureTests/<Suite>/<test>` run prints `** TEST SUCCEEDED **` with 0
  tests executed if the path doesn't match anything (for example a `@Suite("...")` display name
  that differs from its Swift type name), and raw `xcodebuild` exits 0 on it, indistinguishable
  at a glance from a real pass.
  Since #2317 that is caught rather than watched for: pass the scope to the WRAPPER
  (`mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/<Suite>`) and a run that reported
  success while executing no tests at all fails with `NOTHING RAN`, naming the scope as the likely
  cause. That is the reason to scope through the wrapper rather than around it; a raw `xcodebuild`
  still has no gate on it. A scoped run is also exempt from the short-run baseline, and cannot move
  it: the baseline is a full-suite number, so a handful of tests would otherwise read as a 99%
  truncation and then quietly become the bar every later run is measured against.
  Since #2577 the wrapper also says whether the run is still MOVING, which `NOTHING RAN` cannot,
  because that gate can only speak once a run has ended and the run it exists for never ends. On
  2026-08-12 a hang inside a test's untimed wait loop (#2576) went unnoticed for over an hour while a
  second run sat blocked behind the shared lock, and three consecutive status reports said "waiting on
  the suite" when the work had been dead throughout. So the wrapper watches its own log for lines
  REPORTING a test or suite starting or finishing, and prints a loud `NO TEST HAS FINISHED FOR ...`
  once nothing has reported for the stall limit, repeating on that cadence and withdrawing itself if
  progress resumes. It never judges by the log GROWING: that hang wrote 21MB of repeated CoreData
  errors while standing still, so every byte-based or mtime-based signal called it healthy the whole
  time. It WARNS rather than kills, because a wrong kill throws a whole suite's work away and reports
  as a failure nobody caused; the cost of warning is that somebody still has to act on it, and the
  lock stays held until they do.
  Waiting for the shared lock is deliberately NOT a stall and can never trip it. That distinction is
  the whole guard: with several worktrees on this Mac contending for one lock, a run that has not
  started yet is the ordinary case, and a guard that called it a stall would be switched off within a
  day. It is told apart by evidence rather than by a threshold, since flock prints nothing until it
  hands the lock over, so a queued run's log is EMPTY and that is proof rather than inference. That
  state gets its own `STILL WAITING for the shared xcodebuild lock` notice, and a `Got the shared
  xcodebuild lock after ...` line when the wait ends, so a queued run is no longer silently
  indistinguishable from a hung one. The build phase is exempt for the same evidential reason: no run
  has been observed to hang there, so there is no measured number to set a limit from. Retune with
  `OVERTURE_TEST_STALL_LIMIT_SECONDS`, `OVERTURE_TEST_STALL_CHECK_SECONDS` and
  `OVERTURE_TEST_LOCK_NOTICE_SECONDS`.
  A red run that named no failing test is one of THREE things, not two, since #2322. A crashed app
  host is retried once as the known #1331 flake. Code that did not compile is not (#1465). And a run
  that never reached this Mac's TEST SERVICE, whose tell is the daemon's own wording plus a total of
  zero tests executed, is now `test-service-wedged`: it is neither retried nor followed by the pure
  suite probe, because both go through the same `testmanagerd` and would meet the same wedge after
  another full build, and it says so and hands over `pkill -x testmanagerd`. On 2026-08-08 that
  cause spent three full cycles being reported as a crashed app host, which was blameless.
  The same daemon's AGE is read before the lock and mentioned when it is implausibly old (#2323),
  advisory only, never blocking, in the way `prune-stale-registrations.sh` already rides along.
  Retune the threshold in `TESTMANAGERD_OLD_DAYS`; it is set above a healthy reading measured on
  this Mac rather than at a round number, so it does not fire on the ordinary case.
  How long a full run takes is deliberately NOT written down here. It moved as the suite grew and
  the stated figure was wrong by minutes, which matters because the paragraph above tells you to
  check a suspiciously fast run against what a full one costs: an understated number weakens the
  very warning it was there to support (#2532, L32). Every run ends with its own `Suite shape:`
  line giving the wall clock it actually took, so read that.

- **Seeing a guard fail, which every guard here is supposed to have been (L1): `scripts/mutate.sh`
  (#2755).** `scripts/mutate.sh [--at <text> | --at-regex <re>] [--breaks-the-build] <file>
  <perl-expression> [test-scope ...]` breaks the code on purpose,
  runs the suite, restores the file through a trap, and reports which tests went red. Roughly 1600 of the
  suite's declarations are source-text guards, so this is done constantly, and it was hand-rolled every
  time. Use it rather than a fresh one-liner, for the two reasons the hand-rolled version has already
  lied: a substitution that matched NOTHING leaves the suite green for the ordinary reason and reads as a
  surviving guard, and a run piped through anything reports the PIPE's status. It keeps ELEVEN outcomes
  apart, and only the first two are results: CAUGHT, SURVIVED, NOT APPLIED, NOTHING RAN, LANDED
  ELSEWHERE, NOT PROOF, NO RUNNER, DID NOT BUILD, MISPLACED FLAG, PERL VARIABLE and SCOPE MISSED THE
  FILE.
  `OVERTURE_MUTATE_RUNNER` swaps the runner, which is how to drive the shell fixtures or vitest instead
  of the Swift suite. Since #2972 the run's FULL log is KEPT at a named path and printed as `full log:`
  (`/tmp/overture-mutate-run.log`, moved with `OVERTURE_MUTATE_LOG`): only the last 25 lines go to the
  screen, and the exact failure text this file demands in a PR body routinely sits just above that cut,
  which used to mean running the whole mutation again for evidence the run had already produced.
  **Since #3240 every proof also says how much of itself was BUILD rather than tests.** That issue asked
  whether the one to four proofs a PR body carries could share one build, and the measurement says there
  is nothing to share: each proof mutates a different file, each is already incremental on top of the
  build the author's own `scripts/test-all.sh` just made, and what is left is Swift re-typechecking a
  large module for one changed file. Measured 2026-08-31 on this Mac, scoped to a five-test suite whose
  tests take 0.05s: 23.4s with nothing changed at all, 93.6s with one TEST file changed, 145.2s with one
  APP file changed, and 199.2s for the same proof on the pure `OvertureCore` scheme, which is SLOWER and
  so is not the lever either. A proof is therefore 75% to 84% build. The line is printed rather than
  written down here for this document's own standing reason: a measured number in a sentence goes stale
  silently, and one the tool takes on every run cannot (L32, L316).
  The last two are #2820 and are the ones that lied in the CAUGHT direction, which is the worse one,
  since CAUGHT is the verdict quoted as proof for each of those ~1600 guards. Measured 2026-08-16: an
  expression using a pipe as its perl delimiter had its `\|` read as an escaped DELIMITER, reached the
  regex as an alternation with an empty branch, matched the EMPTY STRING at offset 0, and prepended text
  ahead of a shebang. The file stopped parsing, every fixture went red, and mutate.sh said CAUGHT. So it
  now confirms the change landed where it was aimed BEFORE it will run anything. A match that consumed no
  characters is refused outright, which needs nothing declared and catches that incident exactly where a
  diff-based rule cannot (the prepend happened on the first line, so the diff reads as an ordinary
  one-line change). `--at <text>` declares the aim explicitly and refuses a mutation touching any line
  the text does not name, which is the only way the tool can know where a mutation was SUPPOSED to
  land. Since #3080 that aim is LITERAL, because an aim is a LOCATOR rather than a pattern: it used to be
  a regex and said so nowhere at the point of use, so `--at 'Text(SendConfirmCopy.openReview)'` reported
  LANDED ELSEWHERE naming a line nobody wrote, its parentheses having grouped rather than matched. That
  happened six times in one session, each costing a rerun of a scoped Swift suite. `--at-regex` is the
  opt in for an aim that genuinely wants a pattern; it is a separate flag rather than a mode on `--at`
  so which reading is in force is visible at the call site.
  **Since #3344 `--at` may be given MORE THAN ONCE**, each naming one line, and a touched line has to be
  named by one of them. That is for the ordinary two-line shape one aim cannot state: a `set -m` above
  the line it protects, a `return` under the message explaining it. Measured 2026-08-30 while proving
  #3292 and #3264, five correctly aimed mutations came back LANDED ELSEWHERE naming a line one above or
  below the aim, and two were then worked around by hand-editing the file with perl, which is the exact
  sequence this tool exists to stop anybody doing. The two flags MIX and each aim is read the way its own
  flag says. One thing to know before using it: an aim that names NO line is refused on its own, rather
  than being carried by a neighbour that does match. With a single aim a typo could only ever refuse,
  since every touched line fell outside it, so the wrong aim announced itself; with two it would be
  silently covered and a line you believe you named would be uncovered (L98). The perl expression is still genuinely perl
  and is unchanged, but a `NOT APPLIED` whose search text IS in the file literally now NAMES the
  metacharacters being read as a regex, the way `PERL VARIABLE` already names `$0`. It says that only
  with that evidence, never on the mere presence of a metacharacter, so the ordinary typo (text that is
  simply absent) is not blamed on escaping. And a run in which nearly everything went red reads as the instrument misfiring rather than as
  proof. A SCOPED run is exempt from that last one on purpose: a scope naming the one suite holding the
  guard is expected to go entirely red, and a rule condemning it would fire on the common case and be
  switched off within a day (L93).
  The last three are #2995, #2859 and #2993, and all three are one thing: a MALFORMED INSTRUCTION being
  reported as a verdict. A build failure used to be folded into CAUGHT, on the reasoning that the
  compiler caught something, which is true of a mutation whose POINT is that the code stops type-checking
  and false of every other one, where it means the guard never ran at all. That is `DID NOT BUILD` now,
  and the deliberate case declares itself with `--breaks-the-build` rather than silently borrowing
  another outcome's name. `PERL VARIABLE` refuses an unescaped `$0`, `$&` or a `$1` with no capture
  group, which is how the build failures were produced twice in one session on #2988: in a `s///`
  replacement `$0` is perl's own program-name variable, so `isCandidate($0, ...)` interpolates away.
  Write `\$0` when you mean the characters. **Since #3109 it refuses the other sigil too**, an unescaped
  `@` followed by a name, because `@name` is a perl ARRAY and is interpolated in the REPLACEMENT and in
  the PATTERN alike. That one lied in the SURVIVED direction, which is the worse one: measured
  2026-08-22 proving #2839's guard, the expression asked for `"someone@arealpersonsite.com"`,
  `@arealpersonsite` interpolated away, the text that landed was `"someone.com"`, a guard that judges an
  address by its DOMAIN correctly said nothing about a string holding no `@`, and the verdict printed
  was SURVIVED for a guard that works. The aim check structurally cannot catch it, since the
  substitution lands on exactly the line it was aimed at. E-mail addresses are ordinary test data here,
  so write `\@` whenever you mean the character. And `MISPLACED FLAG` refuses a `--` argument sitting where a
  test scope goes: **put `--at` FIRST**, because after the expression it used to fall into the trailing
  scopes, reach xcodebuild as an unrecognised option and send the runner to the PURE suite, so the aim
  check was off and a targeted proof became a full-suite run.

  **`SCOPE MISSED THE FILE` is #3098, and it is the one that lied in the SURVIVED direction.** Hit for
  real on 2026-08-21 while proving #2726: a sentence in `ScoutService.swift` was reworded, scoped to
  `-only-testing:OvertureTests/ScoutStartGateTests`, and mutate.sh reported SURVIVED. The guard was
  fine. The test lives in a SECOND suite in that same FILE, `ScoutStartGateWiringTests`, so the scope
  ran nine real, unrelated tests and never the one under test; re-run against the right suite, CAUGHT.
  `NOTHING RAN` structurally cannot catch that, because something did run, and the caution mutate.sh
  used to print about it was a rule living only in prose (L27). Before believing a SURVIVED, mutate.sh
  now asks whether any suite that NAMES the mutated file actually ran, refuses when none did, and lists
  the suites that do name it so the right scope is in front of you (capped at 15, saying how many of how
  many it dropped, because ScoutService is named by 65 suites and StoreRelocation by 1). The unit is the
  SUITE and not the file, which is the whole of why it works: both suites in that incident live in one
  file, and a per-file rule would have passed it. The other signature #3098 floated, a scope naming a
  suite whose file declares more than one `@Suite`, was measured and rejected: it fires just as hard when
  the scope named the RIGHT suite of the two, which is the common case (L93). Three states are
  deliberately NOT refusals, and each says which it was rather than letting silence stand for a
  measurement (L11): an unscoped run (it ran everything there is), a file no suite anywhere names
  (SURVIVED is then a real finding about the code), and a log with no suite lines at all, which is what
  `OVERTURE_MUTATE_RUNNER` pointed at the shell fixtures or vitest produces.

  **A SURVIVED also says whether the needle is still in the file (#3157).** Four source-text guards
  written on 2026-08-23 passed while the code they guard was deleted, all the same shape: the needle
  also occurs somewhere harmless in the SAME file, so the assertion is answered by that second
  occurrence rather than by the code (L135). `DetachConversationCopy.control` is a PREFIX of
  `.controlHelp` on the next line (#2797); `DraftedDeadEndCopy.line` survived inside an `if false`
  branch (#2674); `onConnectGmail: connectGmail` reaches ArchiveView as well as FollowUpsView (#2967).
  Every one was found the same way, by hand, after the SURVIVED, by grepping the file. So the SURVIVED
  now carries that reading, in three states kept apart because an unmeasured check and a passed one
  look identical from silence (L11): the text is STILL in the file, at named line numbers; it is not,
  which rules that explanation out; or it could not be read as literal text that was in the file, in
  which case nothing was measured and it says so. It is a REPORT on a SURVIVED and deliberately not a
  rule over every guard: a needle that legitimately recurs is common, so a gate on it would fire on
  the ordinary case and be switched off within a day (L93).

- **Which test entry points refuse to call an empty run a pass, and which cannot (#2541).** Zero subjects
  examined is its own outcome and must never read as "everything passed", because the empty result
  arrives exactly when the work has not started (L98). Where each entry point stands, measured
  2026-08-15:
  - `mac/scripts/run-tests-locked.sh`: GATED since #2317. A run that reported success while executing no
    tests fails with `NOTHING RAN`, naming the scope as the likely cause.
  - `pnpm test` (vitest): GATED already, by vitest itself. A filter matching nothing prints
    `No test files found, exiting with code 1` and exits 1. Nothing was added here; it was checked.
    Its SCOPE is a different question and had the opposite defect (#3120): with no config file vitest
    took its default include, which descends into the agent worktrees under `.claude/worktrees/`, so
    the run collected this repo's 16 test files fifteen times over, one copy per nested checkout, and
    reported `Test Files  240 passed (240)` (measured 2026-08-22, 14 worktrees). Not a coverage gap,
    but a half finished branch in a worktree could fail the verdict on a change that never touched it,
    and the count read as thorough while moving with how many agents happened to be running.
    `vitest.config.ts` now names an include anchored inside `src/`, which a nested checkout cannot be
    reached by whatever it is called, and `src/lib/testDiscoveryScope.test.ts` guards both that anchor
    and the other half, that no test file of this repo's own is left outside where the include looks.
  - **A fixture that leaves a PROCESS running: GATED since #3254.** The runner had checked for leaked
    FILES since #2850 and never looked at what was still running, and a leaked process is the worse of
    the two: it holds the run's stdout open so anything capturing that output waits for it (L235), it
    can hold the shared xcodebuild lock, and macOS reaps nothing until the next boot. #3248 found one
    fixture that had been leaking two `sleep 300` per run for as long as it had existed and three
    helpers that orphaned a child per stop, none of it visible to the runner that gates every push.
    ATTRIBUTION is the hard half, not detection: eight fixtures run at once, so a stray in the process
    table belongs to nobody in particular. Each fixture now runs as a background job under `set -m`, so
    it and everything it starts get a process GROUP of their own, and the group answers the question.
    `scripts/lib/fixture-process-leak.sh` holds one implementation, sourced by the runner AND by the
    per-fixture wrapper it writes, so the two cannot drift (L263). Strays are ENDED as well as named,
    because reporting one and walking past it is how they accumulate; the guard that matters there is
    that `fixture_end_process_group` reads its OWN group independently and refuses to end it, since a
    `set -m` that did not take would otherwise have the runner kill itself (L70).
    Since #3292 the fourth of those is fixed rather than declared, and the fix was in PRODUCTION code:
    `heartbeat_stop` was `kill "$1"`, which ends the heartbeat subshell and leaves the `sleep` inside it
    running, on every stop of every detached run. It now ends the process GROUP, and the three runners
    start their heartbeat (and prep's stuck-tool-call watchdog) under `set -m` so there is a group to
    end. The group kill is CONDITIONAL on the pid being its own group leader, which is what `set -m`
    makes it and what nothing else does: `heartbeat_stop` is also called on pids that were not started
    that way, and a group kill on one of those would take down the runner and its claude (L70, L321).
    On its first sweep it found FOUR fixtures leaking, which is the check working rather than the
    conversion having been careless: `run-heartbeat.test.sh` (four `sleep 5`), `sleep-guard.test.sh`
    (one `sleep 1`), `stuck-tool-call.test.sh` (one `sleep 1` per watchdog case) and
    `prep-run-chunking.test.sh` (two `sleep 15`). The first three create their stray deliberately, to
    demonstrate that a bare `kill` on a subshell leaves the `sleep` inside it, and are right to create
    one and wrong to walk away from it: they now use `fixture_run_in_own_group`.
    The fourth is DECLARED rather than fixed, with `shell-fixture-leaks-process: sleep (#3292)`, because
    its stray is created by the production code it runs end to end (`heartbeat_stop` ends the heartbeat
    subshell and not the `sleep` inside it, which is #3248's class unconverted in `run-heartbeat.sh`).
    The declaration is the same shape as `shell-fixture-expects-missing-command:` and for the same
    reason: a rule whose only answers are pass and fail gets switched off the first time somebody meets
    a case it cannot express. It names the COMMAND, so an undeclared stray in a declaring fixture is
    still caught, and it MUST carry an issue number, so it is a debt with an owner rather than a
    permanent exemption (L523, L65). A declared leak is still ended.
  - `scripts/run-shell-fixtures.sh`: GATED since #2541. A fixture that exits 0 having printed no passing
    assertion fails, because that is what a fixture looks like when its body did not run (an early
    return, a loop over an empty list, a guard that skipped every case). All 61 fixtures print at least
    one, so the rule costs nothing and only fires on a fixture that stopped working.
    Since #3245 it also RUNS THE FIXTURES IT IS GIVEN: `scripts/run-shell-fixtures.sh <path> ...` runs
    only those, and no arguments still sweeps everything, which is what `scripts/test-all.sh` calls. Use
    the scoped form to prove one fixture through the runner's own rules, which are the only place those
    rules exist; running the fixture directly gets none of them. Before this the entry point globbed and
    ignored its arguments entirely, so a scoped proof cost the whole sweep (#3237 measures that at 65.7s)
    and said nothing about the path it was handed, which is worse than the cost: an argument that is
    silently ignored is indistinguishable from one that was honoured. A named path matching no fixture is
    REFUSED rather than falling back to the sweep, and a sweep that finds no fixture at all now says
    UNMEASURED and exits nonzero, where it used to print `No *.test.sh fixtures found.` and exit 0 (L98).
    Since #2929 it also says when the run has STOPPED MOVING, which that gate cannot: it can only speak
    once a run has ended, and the run this exists for never ends. Output does not stream here (each
    fixture's block prints after it finishes), so a fixture that hangs used to leave the runner silent
    forever: measured 2026-08-17, one was still alive after roughly 8 minutes holding up the whole
    parallel run and had to be killed by hand. `scripts/lib/fixture-stall-guard.sh` warns on a cadence
    once nothing has STARTED OR FINISHED for the limit, and NAMES the fixtures still going. It reuses the
    Swift runner's rules (`notice_due`, `humanize_seconds` from `mac/scripts/lib/test-progress-watch.sh`)
    and deliberately not its WORDS, which are about xcodebuild and a shared lock this runner does not
    have. Both ends are counted, not just finishes: with eight lanes, seven fast ones would otherwise mask
    a hung one for as long as work remained. It WARNS rather than kills, for #2577's reason. Retune with
    `OVERTURE_FIXTURE_STALL_LIMIT_SECONDS` and `OVERTURE_FIXTURE_STALL_CHECK_SECONDS`.
  - **Anything asking a yes or no question with `cmd | grep -q`: WRONG under `pipefail`, and it fails
    in the direction that reads as a clean answer (#3275).** `grep -q` exits on its first match, which
    kills the producer with SIGPIPE, and `set -o pipefail` makes that 141 the pipeline's status, so the
    condition reads FALSE. Measured 2026-08-30 against a real 1.2MB run log: an EARLY match gave 141, a
    LATE match 0, and no match 1, so an early match and no match are indistinguishable. It had been
    live in `hosted_suites_ran` (the screens readout), where it looked correct only because a SERIAL run
    puts the app-hosted bundle LAST so the match lands near the end; under
    `-parallel-testing-enabled YES` the hosted lines start at line 1406 and four consecutive runs
    reported the screens as NOT VERIFIED having just passed all 49 of them.
    The remedy is a herestring (`grep -q ... <<< "${text}"`), or `grep` with no `-q` redirected to
    `/dev/null` where the file must stay POSIX for `scripts/check-runner-posix.sh`. Since #3275
    `scripts/run-shell-fixtures.sh` scans the PRODUCTION scripts for this shape as well as the
    fixtures, which it had never done, and its needle matches a `-q` anywhere in grep's option cluster
    rather than the one spelling `grep -q`, because `grep -aqF` is what the real defect was written as.
  - **A raw `xcodebuild`: NOT GATED, and cannot be.** It has no wrapper to hold the rule, which is the
    reason to scope through `mac/scripts/run-tests-locked.sh` rather than around it. A raw run also exits
    0 on a `-only-testing:` path that matches nothing.
  - **A hand-written wait loop watching a log: NOT GATED, and the trap is specific.** One on 2026-08-11
    treated ordinary CoreData `Error:` noise as the suite finishing and reported a suite that was still
    running. Wait on the run's own end marker, never on a substring that routine noise can produce.

- **Writing a shell fixture: the assertions come from `scripts/lib/shell-assertions.sh`, which every
  `*.test.sh` sources.** It gives one vocabulary (`pass`, `fail`, `assert_contains`,
  `assert_not_contains`, `assert_equals`, `assert_eq`, `assert_empty`), all reporting through
  `FAILURES` and none exiting early, so a fixture runs every check it has and reports the total.
  Before #2501 each of the 48 fixtures defined its own, and which names existed varied file to file
  (22 had `assert_contains`, 13 `assert_equals`, 10 `assert_eq`), so reaching for the wrong one printed
  `command not found` to stderr, checked nothing, and the fixture still reported every assertion
  passing. `scripts/run-shell-fixtures.sh` now fails any fixture whose output shows bash could not
  resolve a command, which is the half that holds even if a fixture forgets to source the library. A
  fixture that drives a missing dependency ON PURPOSE (`models.test.sh` runs `record_model` with `PATH`
  pointing at nothing) prints `shell-fixture-expects-missing-command: <name>` to declare it; that
  exempts the one command named and nothing else. A fixture keeping its own definition of a helper is
  fine and deliberately still supported: two fixtures read `assert_contains` as
  (desc, needle, haystack), and a definition after the source line wins.
  **Since #3408 the runner also fails a fixture holding a line bash could not PARSE.** It is the same
  defect as the unresolved-command rule wearing different words, and that rule structurally cannot see
  it, because nothing was ever looked up: a line that does not parse was never a command. Found by
  accident on 2026-08-31, and it had been live in two places. `suite-stats.test.sh` held a needle with
  `$(` inside single quotes inside a command substitution on a continued line, which bash 3.2
  mis-parses, so its assertion that a scoped run never writes the duration series had printed nothing at
  all on every sweep since it was written. `pr-completeness-guard.test.sh` held a COMMENT between two
  stages of a pipeline inside a command substitution, which bash 3.2 also refuses: it dropped the `awk`
  stage, left the variable holding the whole lowercased script, and both assertions under it then passed
  on any file containing the word "author" anywhere in it (L135). Both are fixed, and the rule is what
  finds the next one. Two shapes are matched, `: bad substitution` and
  `: syntax error near unexpected token`, each carrying its leading colon so a fixture that merely
  QUOTES the words still passes.

- Since #1967 the Swift tests live in TWO targets, and which one a new test belongs in is decided
  by one question: does it need the app RUNNING?
  - `OvertureTests` (`mac/OvertureTests/`) holds almost everything and is where a new test goes
    unless it renders a view. It is UNHOSTED: it reaches the app's code by compiling it in, not by
    linking a host, so it has no `TEST_HOST` and no dependency on the app target at all.
  - `OvertureHostedTests` (`mac/OvertureHostedTests/`) is only the ViewInspector ones, which render
    a real SwiftUI view and so genuinely need the host process. It is a small fraction of the total.
  - `mac/TestSupport/` holds the helpers both compile (`SourceGuardHelper`, `SwiftSource`,
    `CopyInventory`), in one place so a guard helper cannot drift between the two targets.
  This exists because every test used to run inside the launched app, so one launch fault took all
  of them: on 2026-08-01 a crowded menu bar removed the status item, which terminates a
  `MenuBarExtra` app, and nothing in the Mac app could be verified at all. Measured ON 2026-08-02
  with a deliberate `fatalError()` in `OvertureApp.init`: the pure suite reported
  `Test run with 4802 tests in 690 suites passed`, `** TEST SUCCEEDED **`, exit 0, while the app
  could not start. That figure is what the suite was THAT DAY and is deliberately not updated: it
  is the record of an experiment, not a claim about the suite's current size. For the current size,
  see the readout below.

- **The suite states its own size, every run, unless it cannot honestly state one.**
  `run-tests-locked.sh` ends with a
  `Suite shape:` line giving the tests and suites actually executed, the wall clock, the ratio of
  test Swift to app Swift, and how many test declarations are source-text guards (#2193, #2232).
  Use that line, never a number written in this file, as the reference for "did this run execute
  the whole suite?".
  Since #2821 there is one state in which it deliberately states NOTHING: a run whose test process
  RESTARTED. xcodebuild relaunches the process after an unexpected exit, crash or `.timeLimit`
  timeout, and the totals it then prints are totals of the REMAINDER. Measured 2026-08-16 while
  re-checking #2808's mutations, the line read `Suite shape: 12 tests in 2 suites` for a run that
  had really started 70 across 8 suites. A plausible small number is precisely the answer this line
  must never give, since the reading it exists to support is "was this run short?", so it prints
  `Suite shape: NOT REPORTED` and names the restart instead of summing across a crash, and such a
  run can no longer record its own count as the baseline the short-run gate measures against.
  **Since #3233 the readout also understands a PARALLEL run, which prints no totals line at all.**
  Under `-parallel-testing-enabled YES` xcodebuild stops printing `Test run with N tests in M suites`
  and reports each test on its own line instead (`Test case 'Suite/test()' passed on 'My Mac - xctest
  (63822)' (N seconds)`). Nothing read that, so the whole chain downstream of the count went blind at
  once: the readout said it could not tell, the short-run gate had nothing to compare against a
  baseline and therefore could not fire, and the screens readout (#1995), which looks for
  `Suite "..." passed`, reported the screens as unverified. Measured 2026-08-29 on the audit
  experiment behind milestone 60: barely more than half the suite executed, one of its two workers
  printed 58 lines before its entire share vanished with no crash line anywhere, and the only thing on
  screen was a list of 12 failing tests offered as the whole story. The gate was intact throughout. It
  was blind, not broken (L98, L11). The counts are deliberately not written here, for this document's
  own standing reason: a hand-written suite size drifts and then weakens the very warning it is quoted
  in support of (L32). They are in #3233 and in the fixture's own header. Three things to know about the parallel reading. The count is by
  test NAME rather than by line, because a parameterised test prints one line per case and a retried
  one prints its line again, and an over-count makes a truncated run look longer than it was. The
  DURATION never comes from those per-test seconds, which are elapsed since that WORKER began rather
  than what the test cost (in the real log a one-line boolean reported 64.4s, and the trimmed fixture's
  lines sum to 338.423s for a run that took 95.447): it comes from the run's own elapsed line, or the
  readout says the duration was not reported. And a log carrying BOTH a summary and per-test lines is a
  MIXED run, where the two are SUMMED rather than one preferred (#3266, reversing what #3233 wrote here).
  That is the shape the parallel work produces: one testable parallel, printing per-test lines and no
  summary, and the app-hosted one left serial, printing a summary and no per-test lines. Preferring the
  summary read the hosted suite's 300 as the whole run, so a COMPLETE run of 8,623 was reported as 300
  and refused by the short-run gate (measured 2026-08-30). Note which way that fails: under-reporting by
  96% makes the gate block a healthy push, which is the failure that gets a gate switched off rather
  than trusted. Summing cannot double count, and that is measured rather than assumed: a wholly serial
  run prints no `Test case ... on 'My Mac - xctest (N)'` lines at all. The DURATION is the one number
  not summed, since the parallel reading already takes the run's own elapsed line, which spans both
  testables. The fixtures are those runs' own output, trimmed, at
  `mac/scripts/lib/fixtures/parallel-run-20260829.log` and `mac/scripts/lib/fixtures/mixed-run-20260830.log`;
  the full 839KB parallel log is kept at `~/.overture-mac-test-diagnostics/parallel-experiment-20260829.log`.
  **Since #3243 the COUNT on that line, and the count the short run gate is judged by, come from the
  run's own RESULT BUNDLE rather than from the log text.** Two reasons, and the second is the sharper
  one. A parallel run's stdout is written by several worker processes at once and their per-test lines
  can collide: in the 2026-08-29 experiment log exactly one line was corrupted that way, which is why
  the readable count was 4,874 against the bundle's 4,875. One test is immaterial against a 10 percent
  tolerance; what is not is that the only thing bounding the error is how often two workers write in
  the same instant, which nothing measures and which gets worse with more workers. And the gate
  compares this number against a baseline a SERIAL run recorded, which used to be produced a different
  way (#3265): 8,612 by distinct name in parallel against a serial 8,618, with `CityFromAddressTests`
  alone printing 17 case lines under 6 distinct names. Two numbers being CLOSE is worse than their
  being obviously different, because it reads as trustworthy while comparing two things that are not
  the same quantity.
  `totalTestCount` is ONE quantity however the run was parallelised, and it is by test NAME. Measured
  2026-08-30 on a real serial run: `totalTestCount` 8,626 against a summary line of 8,626, while the
  same bundle's per-configuration figures come to 8,801, because 45 tests ran with dynamic parameters
  over 220 runs. Names on both sides of the comparison, which is what the gate needs.
  Three things to know. Every way the read can FAIL comes back empty rather than zero, because zero is
  a real measurement that the empty-run gate acts on, so a failed read arriving as zero would fail a
  healthy run and name the wrong cause (L98, L11); the log parsers stay as the fallback and the readout
  SAYS so when it fell back, which is a warning only in the case that needs one. A RESTARTED run is
  refused the bundle count deliberately: its text totals are the totals of the remainder after the
  relaunch (#2821), and whether the bundle counts the whole run or the remainder is not something
  anybody has measured, so substituting an unmeasured whole-run count there is the one direction that
  disarms the gate (L82). And it costs one `xcresulttool` call, measured at 6.2s against a suite of
  about 330s; `OVERTURE_XCRESULTTOOL` is the seam the fixture drives it through.

  **Since #3165 the first of those two invariants is measured by a different number.** It used to be the
  rows whose reply is still OPEN, which #2985 narrowed it to for a correct reason (`ReplyIdentity.answering`
  short-circuits once a reply is handled, and asserting through it fired when Dan answered one, which is the
  workflow succeeding). What that left was a rule whose corpus empties whenever he is up to date, which is
  most of the time: measured 2026-08-27, 1018 shows, 5 replied rows, ZERO still open, so it had asserted
  nothing about his data for as long as this clone had recorded. The claim that still holds for a handled
  row is the one `answering` is BUILT from, that the contact holding the writer's address is a PEER of the
  row that recorded the reply, and asking the peers directly survives the reply being answered because it is
  a fact about how contacts are grouped rather than about the reply's state. It runs over 4 rows today where
  it ran over 0, and a mutation removing the peer requirement goes red on Dan's real data. The readout and
  the record's key were renamed with it (`writer=`, not `open=`), because a key named `open` counting
  something else is how one word comes to name two units (L118); no history was lost, since the old count
  was zero on every machine that ever wrote that file.

  **Since #1995 a third line says whether THIS run verified the SCREENS.** The app-hosted tests are the
  only ones that render a real SwiftUI view, and since #1967 a launch fault costs them alone: the pure
  suite passes, the runner says so, and work carries on correctly. What nothing recorded is when they last
  actually ran, so a host broken across a stretch of UI work leaves the screens unverified for as long as
  that lasts, silently, and the work most likely to be happening in that window is exactly the work they
  cover. It is judged by the hosted suites' OWN `@Suite` display names, derived from
  `mac/OvertureHostedTests/` rather than listed anywhere, and by a run reporting one of them as PASSED
  rather than merely naming it: a run that started that bundle and died in it names those suites exactly
  as a passing run does. The count of test BUNDLES was considered and is a proxy rather than evidence, so
  it is not used: it says two bundles ran, never which two.
  Four states, and only one of them is good: `verified by this run`, `NOT VERIFIED ... last passed on
  <date> (<n> days ago)`, `NOT VERIFIED ... no run on this clone has ever verified them`, and `UNMEASURED`
  when no suite name could be read at all, which must never be folded into the second (L11). The record is
  `.overture-hosted-suite-seen` beside the repo, gitignored, with the date INSIDE the file, all three on
  `.overture-live-corpus-seen`'s precedent and for its reasons. A run that did not verify them LEAVES IT
  ALONE, which is the whole mechanism: stamping every run would move the date forward while the host
  stayed broken and the age would always read zero.

  **Since #2991 a second line beside it says whether the LIVE STORE invariants measured anything.**
  `ReplyInvariantsLiveStoreTests` prints a corpus line every run giving how many rows each of its
  invariants could examine, and measured 2026-08-19 it read `0 whose writer a contact holds, 0 reached-out
  rows in play`: both passed having asserted nothing about anything, and the only thing separating that
  from a clean bill of health was a printed line thousands of lines up a log nobody reads. That is L182
  exactly, and this one goes to zero precisely when Dan finishes his outreach work, so it can sit there
  for months. What is dormant is not the RULE (the synthetic suite still has teeth, confirmed by
  mutation) but the ability to notice an unforeseen SHAPE in his real data, which is the whole reason
  the live suite exists (#2150). Four states, kept apart because an unmeasured check and a passed one
  look identical from silence (L11): `measuring` with both counts, `PARTLY DORMANT` naming WHICH half
  had no rows and giving the other's real count, `DORMANT` when neither did, and `NOT REPORTED` when
  the run carried no corpus line at all. That last one is the one to read carefully: it is what a
  SCOPED run produces, and treating its absence as nothing to report would make the emptiest possible
  failure look like the cleanest possible pass (L98).
  **It also says HOW LONG**, which is the half worth acting on: "both measured nothing today" is much
  weaker than "neither has measured anything since May (114 days)", because only the second says
  whether to care. That needs a record, `.overture-live-corpus-seen` beside the repo, gitignored and
  per machine on the exact precedent of `.overture-eval-last-run` (#1867). Two things about it are
  load bearing. The DATE lives INSIDE the file rather than being its mtime, because a clone rewrites
  every mtime and would reset the dormancy to zero, which is the one number this must never get wrong.
  And a run only WRITES the invariant it actually measured: a dormant run leaves the record alone, and
  a run with no corpus line leaves it alone too, or the last real measurement would be stamped over
  every run and the duration would always read zero, which is the defect wearing a date. Both refusals
  are pure (`live_corpus_seen_update` returns the new contents, the caller only writes them) and both
  were seen to fail.
  Since #2600 a FAILING run then reprints xcodebuild's own `Failing tests:` block, with a count, as
  the last thing on screen. Read that rather than searching the log: a failure raised by
  `Issue.record` prints only `recorded an issue` while an `#expect` prints `Expectation failed:`, so
  grepping for the second phrase under-counts. On 2026-08-12 a branch read that way was reported as
  having two failures and had eight. The counts here used to be hand-written and both had drifted badly, which
  quietly weakened the warning two paragraphs up: a stated total is exactly what someone checks a
  suspicious scoped run against, so a wrong one is worse than none (L32). `AgentsDocSuiteCountsTests`
  fails if a hand-written count is ever put back.

- The pure suite has its own scheme, `OvertureCore`, which does NOT build the app. Use it
  (`xcodebuild -scheme OvertureCore -destination 'platform=macOS' test`) to verify domain logic while
  the app is broken or mid-refactor; it does not even need the app to compile. This matters because
  `-only-testing:OvertureTests` on the combined `Overture` scheme does NOT avoid the app: xcodebuild
  still prepares and launches the host, and a crash there decided the exit code even though every one
  of the pure tests passed. `run-tests-locked.sh` falls back to this scheme automatically on a CRASH, so
  a dead host reports "the PURE suite PASSED, the failure above is the APP HOST, not your code"
  instead of one undifferentiated red. `PureSchemeExcludesTheAppTests` fails if the app is ever put
  back into that scheme.
