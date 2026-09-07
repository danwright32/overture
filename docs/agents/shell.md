# Shell conventions in this repo

Four rules about writing shell here, each from a failure that read as a clean pass.

Split out of `AGENTS.md` in #3640, which was over the character limit for a file loaded
into every session. The text below is unchanged: these are dated measurements, and
rewriting one destroys the record. `AGENTS.md` names each rule and points here.

- **Judging whether a script succeeded: capture its status directly, never through a pipe.**
  `some-script.sh | tail -5` reports `tail`'s exit status, not the script's, so a script that died
  instantly on an unbound variable and printed nothing at all reads as a clean pass. That happened
  on 2026-08-11 to a merge-script fixture and sent the next twenty minutes in the wrong direction
  (#2502). It is the same shape as the `NOTHING RAN` trap above, and the habit that hides it (piping
  through `tail` or `rg` to keep the output short) is exactly the habit anyone working at speed
  reaches for. Two tells worth knowing: NO OUTPUT AT ALL from something that normally prints a line
  per check means it died rather than passed, and `set -o pipefail` or `${PIPESTATUS[0]}` is what
  makes the reading honest when a pipe is genuinely wanted.

- **A script that changes its own working directory captures its location FIRST: `scripts/script-self-location.test.sh`
  (#3481).** `$0`, and `BASH_SOURCE[0]` for a top level script, are the path the script was INVOKED by,
  which is usually relative. Re-deriving a directory from either AFTER a `cd` resolves against the new
  working directory, so the same expression works for one invocation and silently misses for another
  (L372). Write `DIR="$(cd "$(dirname "$0")" && pwd)"` above the `cd`, and use `${DIR}` everywhere after.
  Hit for real on 2026-09-02: `mac/build-install.sh` cds into `mac/` and then sourced
  `"$(dirname "$0")/scripts/lib/build-provenance.sh"`, so invoked the way this file documents
  (`mac/build-install.sh` from the repo root) it resolved to `mac/mac/scripts/lib/...` and missed. The
  install SUCCEEDED, the bundle was replaced and correctly signed, and only the provenance record the
  freshness panel reads was skipped, which is the worst shape for this.
  It was not one instance: seven sibling scripts had it too, four of them production
  (`analyse-freeze-load.sh`, `check-fixture-corpus-drift.sh`, `check-temp-dir-leaks.sh`,
  `freeze-measure.sh`), each capturing `SCRIPT_DIR` one line AFTER cding to the repo root. That happens
  to resolve when they are run from the repo root, which is how everyone runs them, and does not when
  they are run from inside `scripts/`. Measured 2026-09-04: `cd scripts && ./check-fixture-corpus-drift.sh`
  answered `/…/lib/scratch.sh: No such file or directory` and then `UNMEASURED`. The guard is derived
  from the tree rather than a list somebody maintains, and it exempts only itself, because it has to
  name the forbidden spellings in order to search for them (L245, L96).

- **`find` in a SCRIPT is the real find; only a command typed into a session is shimmed
  (#2860/#2959, measured, `scripts/find-is-not-shimmed.test.sh`).** Inside a Claude Code session `find`
  is a shell function running `bfs`, which refuses the relative timestamp form both BSD and GNU find
  accept (`-newermt "-60 minutes"` answers `Invalid timestamp`). Both issues assumed that split reached
  scripts. It does not: the shim is a shell FUNCTION and is not exported, so it never reaches a script
  run as a subprocess. Measured 2026-09-04 in one session on one machine, inline versus from a
  `#!/usr/bin/env bash` script: `command -v find` answers the function and REFUSES the relative form
  inline, and answers `/usr/bin/find` and ACCEPTS it from the script.
  So no script needed changing, and a rule making every script spell `/usr/bin/find` would have been
  noise guarding nothing (L93). What is genuinely exposed is an ad-hoc `find` typed into a session, by
  an agent or by Dan with the `!` prefix, which no repo convention can reach: prefer an ISO stamp there,
  which is what `scripts/tidy-checkout.sh` computes with `date` (#2842).
  The fixture exists because that is a PREMISE about the environment rather than a fact about this code,
  and a premise written down as a dated sentence is one nobody re-measures (L316, L336). It carries its
  own positive control, a stand-in on PATH that refuses the relative form the way bfs does, so it can
  tell "no shim" from "measured nothing" (L171). If the harness ever exports the shim, it goes red and
  names what changed.

- **Scratch in any script: `overture_scratch_dir` / `overture_scratch_file` from
  `scripts/lib/scratch.sh` (#3258), or `fixture_scratch_dir` / `fixture_scratch_file` in a fixture.**
  On macOS `mktemp -d` and `mktemp -t NAME` IGNORE `TMPDIR` unless the path is spelled out in the
  template, so a bare one writes to the shared per-user temp folder, which macOS clears only at boot and
  which no check in this repository can see into. #3249 converted the 81 fixtures; #3258 converted the
  production scripts, 13 call sites across 10 files, and the guard in
  `scripts/lib/shell-assertions.test.sh` now scans every tracked `*.sh` rather than the fixtures alone.
  Read what the measurement said, because it changes what this is FOR: on this Mac after 16 days of
  uptime the shared folder held 52,515 entries and ZERO matched any shape these scripts make. They clean
  up. This is not reclaiming disk, and saying it were would be a number nobody checked. It is about
  VISIBILITY, so a script whose cleanup stops working leaks where something can see it rather than
  silently, which is #3065 measured at 52 directories a run on the Swift side before anybody noticed.
  Two files are exempt by name, `shell-assertions.sh` and `scratch.sh`, because they DOCUMENT the
  forbidden forms in order to forbid them and a scan condemning them would be condemning its own remedy.
