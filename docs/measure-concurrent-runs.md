# Measuring a check and a Prep run going at once (#2762)

This is the session that unblocks the rest of #2620. It is a Dan-at-the-machine job: it starts two real
detached runs and spends real usage, so it is prepared in advance and run with him present, never handed
to an agent.

## What it is for

Two limits stop a paid run, and both were derived from a measurement taken while nothing else was going:

- `PREP_STALL_LIMIT_SECONDS` (1200), in `mac/scripts/prep-run.sh`
- `RunTimeouts.reachabilityProbe` (600), in `mac/Overture/Domain/RunTimeouts.swift`

A chunk parked on a rate limit writes nothing, and writing nothing is exactly what the stall guard reads
as a stall. So the first thing new concurrency can break is the guard that protects paid runs, and the
kill reads as a normal stop. Both limits get re-derived from this session's numbers **before** #2765 or
#2761 ships. That order is Dan's call, 2026-08-18.

The session also answers the question #2620 opened and nobody can answer from the code: whether two
concurrent detached runs hit a plan rate limit. The real budget is up to sixteen concurrent claudes
(check 10, prep 1, scout-extract 4, reply-classify 1), and the last two fire on their own.

## What makes it safe

Four things, all enforced by the script rather than remembered. Three are checked BEFORE it spends
anything; the fourth is checked after, because it is a fact about what the runs actually did.

1. **A scratch support directory.** It refuses to run against `~/Library/Application Support/Overture`
   or the Debug folder, including through a symlink. Nothing it does can reach the live store, and a
   running Overture never sees the results.
2. **Disjoint shows.** #2765 is what makes an overlap safe and it does not exist yet, so the two queues
   must share no show. The script refuses if they do and names the show. This costs the measurement
   nothing: it needs the check to carry *enough* shows, never particular ones.
3. **Nothing runs without `--yes`.** Run it once without, read the plan, then add it.
4. **It refuses to REPORT a measurement of the wrong configuration** (#3005). After both halves finish and
   before any number is printed, it reads what each run recorded about ITSELF: the check half must have run
   on the lookup model and FANNED OUT, the drafting half must have run on the drafting model and stayed ONE
   stream. Any of those wrong and it refuses, naming which half and what it actually was, and exits 3.

   This exists because on 2026-08-18 the peak, both wall clocks and both cost readings all looked perfectly
   healthy while half the session was running the wrong KIND of run entirely (#2980): it measured 15 sonnet
   lookups rather than 10 lookups beside 1 opus drafting run. A person found it by reading `prep-run.log`.
   An instrument that cannot tell you it measured the wrong thing produces its most reassuring output
   exactly when the work was not what you asked for.

   A refusal does not mean the usage was wasted in vain: the runs happened and the samples file is still
   written, so it names where to find it. What it will not do is print numbers you would go on to quote.

It does **not** lift the app's exclusion between the two slots. That exclusion is live safety code and
lifting it early, to take a measurement, would mean shipping a weakened control. Driving the two runner
scripts directly needs no such change and measures the thing actually in question, which is the machine.

## Running it

1. Pick a scratch directory.

```
export OVERTURE_SUPPORT_DIR="$HOME/overture-2762-measure"
```

2. Build two queue files. The check queue needs **at least 10 shows** so it genuinely fans out:
   `split_queue_into_chunks` makes `min(items, OVERTURE_PREP_MAX_PARALLEL)` chunks, so a convenient
   three-show run is three claudes and never reaches the case in question. The archived runs under
   `~/Library/Application Support/Overture/check-run-archives/` and `prep-run-archives/` are real
   work-lists to copy from. Make sure no show appears in both; the script checks, but picking two
   different nights is the easy way.

3. Read the plan without starting anything.

```
scripts/measure-concurrent-runs.sh --prep-queue /path/to/prep-queue.json --check-queue /path/to/check-queue.json
```

4. Start both runs.

```
scripts/measure-concurrent-runs.sh --yes --prep-queue /path/to/prep-queue.json --check-queue /path/to/check-queue.json
```

## Reading what it prints

- **peak concurrent processes.** This is the evidence, not the wall clock. A run whose two halves never
  actually overlapped produces a perfectly good duration and answers nothing. If the peak is well below
  eleven, the two runs did not really compete and the session has to be repeated.
- **the samples file.** One row per sample, kept beside the summary so the shape over time can be read
  rather than only its maximum. A long flat stretch at a low count is what a rate limit looks like from
  outside.
- **`contended`** on each run's `runCost`. Both runs should report `true`. If either says `false`, they
  did not overlap and the numbers are solo numbers wearing a co-run label.
- **a stall stop.** The script says so explicitly when it finds one. That is the reading this session
  exists for: work out whether the run was genuinely stalled or parked waiting on a rate limit before
  changing either limit.

Repeat it more than once, at the hour Dan actually runs a Prep run, since the two runs that fire on
their own are the two he cannot schedule around.

## What to do with the numbers

Record the peak, both wall clocks and both stall outcomes on #2762, then re-derive the two limits. A
stall stop must be able to tell "stalled" apart from "waiting on a rate limit"; until this session has
been run, nobody knows what the second one looks like in the log, which is why no detector for it has
been written (a theory built from the symptom is cheap to believe and expensive to ship, L177).

One coupling to settle in the same pass, pinned by
`ContendedChecksDoNotPoolTests.aContendedRoundSlowerThanTheSoloCeilingIsRefusedRatherThanLearned`: the
per-round ceiling `ProbeDurationHistory.isComparable` applies is `RunTimeouts.reachabilityProbe`, and it
does not move for a contended run. If a real co-run round is slower than that, every contended sample is
refused as "a run that went wrong", the contended class can never fill, and the bar goes on quoting its
constant while real evidence is thrown away every run. Nothing fails; the history simply stays empty.
