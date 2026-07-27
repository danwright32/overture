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

    // Even split with the remainder spread across the FIRST chunks (sizes differ by at most one). The
    // slowest single chunk is what sets wall-clock, so no chunk should be materially larger than another.
    const base = Math.floor(items.length / chunkCount);
    const extra = items.length % chunkCount;

    let offset = 0;
    for (let c = 0; c < chunkCount; c++) {
      const size = base + (c < extra ? 1 : 0);
      const slice = items.slice(offset, offset + size);
      offset += size;
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
