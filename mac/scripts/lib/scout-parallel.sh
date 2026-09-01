#!/usr/bin/env bash
# #1028: run scout-extract's sources concurrently instead of one long sequential pass.
#
# Sonnet reads every pinned page and follows each event to its detail page for the venue, which is
# accurate but slow: a 2026-07-17 run took 16 minutes for 18 sources, and it was a bare, opaque wait on
# an action Dan kicked off by hand. The sources are independent (each is its own page read plus its own
# detail fetches) until the app reconciles them, so the run splits the work-list into chunks and drives
# one claude per chunk at the same time, cutting wall-clock roughly in proportion to the chunk count.
#
# The app never sees any of this. It still writes ONE queue, polls ONE progress file, and ingests ONE
# results file, in the same shapes as before. Chunking lives entirely inside the runner, so every guard
# the sequential path grew (results-guard's not_read backstop, the derived progress count, the model
# stamp) keeps working unchanged: they operate on the ONE merged results file against the ONE full queue.
#
# Two pure functions carry the load, and this is where a silent loss of Dan's shows would hide:
#   split_queue_into_chunks   partitions the queue so every sourceId is in exactly one chunk. Because the
#                             partition is disjoint, the merge is a plain concatenation and there is no
#                             cross-chunk dedup to get wrong.
#   merge_chunk_results       unions the per-chunk results into the file the app reads, in the queue's
#                             own order, skipping any chunk still mid-write rather than reading it as zero.
#
# NO APOSTROPHES inside the node programs below: each is one single-quoted bash string, and a raw quote
# ends it early, which is exactly how #853 silently gutted the runner prompt. results-guard.sh carries
# the same warning for the same reason.

# split_queue_into_chunks <queue> <max_parallel> <out_dir>
#
# Splits <queue>.items into at most <max_parallel> CONTIGUOUS chunks, writing each as its own valid
# ScoutExtractQueue to <out_dir>/chunk-queue-N.json (N from 1). Prints the number of chunks written, so
# the caller knows how many claude processes to launch. Never makes an empty chunk: a queue smaller than
# the cap yields one chunk per source, and a cap of 1 yields a single chunk holding the whole queue,
# which is byte-for-byte the sequential behaviour the parallel path replaces.
#
# Clears any chunk-queue-*.json already in <out_dir> first, so a smaller run cannot inherit a larger
# previous run's leftover chunks and hand a claude a work-list that was never asked for this time.
#
# Degrades to writing nothing and printing 0 (no node, or a missing/unparsable/empty queue): the caller
# treats 0 as "nothing to parallelize" and there is nothing to lose.
split_queue_into_chunks() {
  local queue="$1" max_parallel="$2" out_dir="$3"
  command -v node >/dev/null 2>&1 || { echo 0; return 0; }
  mkdir -p "${out_dir}" 2>/dev/null || true

  # Old chunk queues go before we write new ones, so a stale chunk from a bigger previous split can never
  # be launched as part of this run.
  rm -f "${out_dir}"/chunk-queue-*.json 2>/dev/null || true

  # No apostrophes anywhere in the program below: it is a single-quoted shell string and one would end
  # it, at which point the whole file stops parsing. Write "the whole queue" rather than the possessive.
  # The same rule `mac/scripts/lib/models.sh` states, for the same reason.
  node -e '
    const fs = require("fs"), path = require("path");
    const [queuePath, maxRaw, outDir] = process.argv.slice(1);

    const read = (p) => { try { return fs.readFileSync(p, "utf8"); } catch { return null; } };
    const parse = (s) => { try { return JSON.parse(s); } catch { return null; } };

    const queue = parse(read(queuePath) ?? "");
    const items = Array.isArray(queue?.items) ? queue.items : [];
    if (!items.length) { console.log(0); process.exit(0); }

    let max = parseInt(maxRaw, 10);
    if (!Number.isFinite(max) || max < 1) max = 1;

    // One chunk per source when there are fewer sources than the cap, never an empty chunk.
    const chunkCount = Math.min(max, items.length);

    // #3357 Phase 1.4: DEALT ROUND ROBIN, not sliced into contiguous ranges. Sizes still differ by at
    // most one, because dealing one at a time is what an even split IS; the slowest single chunk still
    // sets wall clock and no chunk is materially larger than another.
    //
    // Why the arrangement matters at all. The queue arrives grouped by source, so a contiguous slice was
    // very nearly one venue per chunk. Two consequences, and the second is the one that bites: a killed
    // chunk lost one ROOM rather than a spread, so loss correlated with difficulty; and any chunk to
    // chunk comparison compared VENUES rather than chunk sizes, which is what Phase 5 would have been
    // measuring without knowing it.
    //
    // Measured 2026-09-01 on the archived 97 item run: one host supplies 43 of 97 listings and the top
    // two supply 57. Sliced contiguously into ten the mean single-host share of a chunk is 0.55; dealt
    // round robin it is 0.44, which is the mixture of the whole queue and the best a fair deal can do.
    //
    // This supersedes one show per stream, which is unreachable at these sizes: the splitter makes
    // min(items, MAX_PARALLEL) chunks and `prep-run.sh` records why ten is a ceiling, so a 97 item queue
    // would need 97 concurrent web fetching processes.
    //
    // The partition is unchanged in every respect that anything downstream relies on: disjoint, every
    // item exactly once, never an empty chunk, and a cap of 1 still yields one chunk holding the whole
    // queue in its original order, byte for byte. What changes is only WHICH chunk an item lands in.
    for (let c = 0; c < chunkCount; c++) {
      const slice = [];
      for (let i = c; i < items.length; i += chunkCount) slice.push(items[i]);
      const chunkQueue = {
        version: queue.version,
        generatedAt: queue.generatedAt,
        items: slice,
      };
      fs.writeFileSync(
        path.join(outDir, `chunk-queue-${c + 1}.json`),
        JSON.stringify(chunkQueue, null, 2),
      );
    }
    console.log(chunkCount);
  ' "${queue}" "${max_parallel}" "${out_dir}" 2>/dev/null || { echo 0; return 0; }
}

# merge_chunk_results <queue> <out_dir> <results>
#
# Unions every parseable <out_dir>/chunk-results-*.json into <results>, ordered by the queue so the file
# is stable across ticks (the app polls it, and the progress count is its length). Called repeatedly by
# the runner's heartbeat while the chunks work, and once more after they exit, so it only ever needs to
# reflect what is on disk RIGHT NOW.
#
# Skips a chunk file that does not parse: a chunk mid-rewrite is normal (the prompt has each chunk rewrite
# its whole file after every item), and reading it as zero would be a worse lie than waiting a tick. If NO
# chunk parses yet, <results> is left exactly as it was, never replaced with an empty file that would read
# as a finished, empty run.
#
# Does NOT synthesize a result for a source no chunk reported: that is results-guard's job at the end,
# against the FULL queue, where a not_read backstop belongs. Here a still-missing source is simply not
# present yet, which is the honest state mid-run.
# #1597: the id field and results version are parameters, so the reachability check reuses this exact
# merge instead of carrying a near-identical copy that would drift. Defaults are scout-extract's, so
# every existing call site is unchanged.
# report_short_chunks <chunk_dir>
#
# #2506: says out loud which chunks came back with fewer results than their own queue held, and which
# sources those chunks never reported. Prints one line per short chunk and returns 1 when any chunk was
# short; prints nothing and returns 0 when every chunk reported in full.
#
# Why this is separate from the whole-queue backstop in results-guard.sh: that one runs against the FULL
# queue after everything has exited and writes a `not_read` for any source with no result, which is the
# right net but says nothing about WHERE the loss happened. On 2026-08-11 chunk 2 was given 7 sources and
# wrote 6, and the merge accepted the short chunk without comment, so the only visible fact was a run
# sitting at 26 of 27 forever. Attributing the loss to a chunk turns that into a reportable outcome, and
# it is the fact that names the log worth reading (that chunk log was zero bytes: see report_chunk_log).
#
# Degrades to reporting nothing and returning 0 with no node, or no chunk dir: a run with no chunks at
# all (a node-free machine falls back to one process) has no chunk to be short, and must not read as a
# failure.
report_short_chunks() {
  local out_dir="$1" report status
  command -v node >/dev/null 2>&1 || return 0
  [ -d "${out_dir}" ] || return 0

  report="$(node -e '
    const fs = require("fs"), path = require("path");
    const [outDir] = process.argv.slice(1);

    const read = (p) => { try { return fs.readFileSync(p, "utf8"); } catch { return null; } };
    const parse = (s) => { try { return JSON.parse(s); } catch { return null; } };

    // Cannot even list the chunks: that is UNKNOWN, never "every chunk reported in full". An empty
    // success here would be the one thing this check must never say without having measured it (L11).
    let files;
    try {
      files = fs.readdirSync(outDir).filter((f) => /^chunk-queue-\d+\.json$/.test(f)).sort();
    } catch { process.exit(4); }

    let short = 0;
    for (const f of files) {
      const n = f.match(/(\d+)/)[1];
      const queued = (parse(read(path.join(outDir, f)) ?? "")?.items ?? [])
        .map((i) => i?.sourceId).filter(Boolean);
      if (!queued.length) continue;

      const resultsRaw = read(path.join(outDir, `chunk-results-${n}.json`));
      const parsed = parse(resultsRaw ?? "");
      const wrote = Array.isArray(parsed?.results) ? parsed.results : null;
      const reported = new Set((wrote ?? []).map((r) => r?.sourceId).filter(Boolean));
      const missing = queued.filter((id) => !reported.has(id));
      if (!missing.length) continue;

      short += 1;
      // NO APOSTROPHES in these strings or this comment: the whole program is one single-quoted shell
      // string, and a raw quote ends it early (#853).
      const nothing = wrote === null ? " (it wrote no results file at all)" : "";
      console.log(
        `scout-extract: chunk ${n} reported ${queued.length - missing.length} of ${queued.length} ` +
        `sources${nothing}. Never reported: ${missing.join(", ")}`);
    }
    // 3, not 1: an uncaught throw in this program also exits 1, and "a chunk came back short" and "this
    // check fell over" are different answers that must not share one status (L53).
    process.exit(short ? 3 : 0);
  ' "${out_dir}" 2>/dev/null)"
  status=$?
  [ -n "${report}" ] && printf '%s\n' "${report}"

  case "${status}" in
    0) return 0 ;;   # measured: every chunk reported in full
    3) return 1 ;;   # measured: at least one chunk came back short, and it is named above
  esac

  # Anything else means the check itself did not run to a verdict. Saying nothing would read exactly like
  # a clean run, so say what is actually known: nothing. 2 is neither of the measured answers, so a caller
  # that ever starts branching on this cannot mistake it for one.
  echo "scout-extract: could not check whether any chunk came back short (the check exited ${status}). Whether a chunk lost sources is UNKNOWN here; the full-queue guard still speaks for every source."
  return 2
}

# report_chunk_log <chunk_log> <chunk_number>
#
# #2506: folds a chunk log tail into the run log, and says so explicitly when there is no tail because the
# chunk wrote NOTHING. A zero byte log is the signature of a worker that died without recording a thing,
# and `tail` of an empty file is empty, which reads exactly like a chunk that simply had a quiet finish.
# Returns 1 for a chunk that logged nothing, so the caller can treat it as an outcome rather than silence.
report_chunk_log() {
  if [ -s "$1" ]; then
    echo "--- chunk $2 log tail ---"
    tail -n 4 "$1" 2>/dev/null || true
    return 0
  fi
  echo "--- chunk $2: NO LOG AT ALL. Its worker died without recording anything, so there is no reason available for whatever it failed to report."
  return 1
}

merge_chunk_results() {
  local queue="$1" out_dir="$2" results="$3" id_field="${4:-sourceId}" out_version="${5:-1}"
  command -v node >/dev/null 2>&1 || return 0

  node -e '
    const fs = require("fs"), path = require("path");
    const [queuePath, outDir, resultsPath, idField, versionRaw] = process.argv.slice(1);

    const read = (p) => { try { return fs.readFileSync(p, "utf8"); } catch { return null; } };
    const parse = (s) => { try { return JSON.parse(s); } catch { return null; } };

    const queue = parse(read(queuePath) ?? "");
    const order = (Array.isArray(queue?.items) ? queue.items : []).map((i) => i[idField]);

    let files = [];
    try {
      files = fs.readdirSync(outDir).filter((f) => /^chunk-results-\d+\.json$/.test(f)).sort();
    } catch { files = []; }

    // Collect every parseable chunk result. A chunk mid-write simply does not contribute this tick.
    const byId = new Map();
    let newestGeneratedAt = null;
    let contributed = false;
    for (const f of files) {
      const parsed = parse(read(path.join(outDir, f)) ?? "");
      if (!parsed || !Array.isArray(parsed.results)) continue;   // absent or half-written: skip, do not zero
      contributed = true;
      if (typeof parsed.generatedAt === "string" &&
          (newestGeneratedAt === null || parsed.generatedAt > newestGeneratedAt)) {
        newestGeneratedAt = parsed.generatedAt;
      }
      for (const r of parsed.results) {
        if (r && r[idField] && !byId.has(r[idField])) byId.set(r[idField], r);
      }
    }

    // Nothing parseable yet: leave the results file untouched. Writing an empty one here would read as a
    // run that finished and found nothing, and the progress-watcher counts exactly this file.
    if (!contributed) process.exit(0);

    // Queue order first (stable, and what the app expects), then any stragglers not in the queue (a
    // defensive tail that a disjoint partition should never produce).
    const ordered = [];
    const seen = new Set();
    for (const id of order) {
      if (byId.has(id)) { ordered.push(byId.get(id)); seen.add(id); }
    }
    for (const [id, r] of byId) {
      if (!seen.has(id)) ordered.push(r);
    }

    const out = {
      version: parseInt(versionRaw, 10) || 1,
      generatedAt: newestGeneratedAt ?? new Date().toISOString(),
      results: ordered,
    };
    fs.writeFileSync(resultsPath, JSON.stringify(out, null, 2));
  ' "${queue}" "${out_dir}" "${results}" "${id_field}" "${out_version}" 2>/dev/null || true
}
