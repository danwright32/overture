#!/usr/bin/env bash
# What a contact check actually searched for, on one show (#2996).
#
# When a check comes home empty, the useful question is "what did it search for", and until this the
# answer meant reading raw JSONL by hand. That is how #2983 was diagnosed: extracting one run's 22 web
# calls showed not one of them named the company whose contact page publishes an address, which turned
# a vague "the check missed it" into a precise defect.
#
# A READER over evidence that already exists, never a new recording. The queue is archived per run
# (#1878, #2760) and since #3446 so are the event streams, each under the same run stamp.
#
#   scripts/what-the-check-searched.sh "Kestrel Quartet"
#   scripts/what-the-check-searched.sh kestrel-2027-04-18-rowan
#
# THREE exit codes, and the third is the one that matters: 0 found something, 1 the show appears in no
# archived run, 2 UNMEASURED, meaning there are no archives to look in at all. A support directory with
# nothing in it and a show nobody checked leave the same empty result, and the emptiest possible failure
# must not read as the cleanest possible answer (L98, L11).
set -uo pipefail

SUPPORT="${HOME}/Library/Application Support/Overture"
QUERY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --support) SUPPORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) QUERY="$1"; shift ;;
  esac
done

if [[ -z "${QUERY}" ]]; then
  echo "what-the-check-searched: name a show, by group name or natural key." >&2
  exit 2
fi

command -v node >/dev/null 2>&1 || { echo "what-the-check-searched: needs node." >&2; exit 2; }

# No apostrophes anywhere below: the whole program is a single-quoted shell string and one would end
# it. Say "the whole chunk" rather than the possessive.
node -e '
const fs = require("fs"), path = require("path");
const [support, query] = process.argv.slice(1);
const needle = query.toLowerCase();

// Both slots: a check normally does this work, but a Prep run legitimately runs in either (#3004), and
// looking in only one would answer "never checked" about a show that was.
const slots = ["check", "prep"];
let archivesSeen = 0;
const hits = [];
const unreadable = [];

for (const slot of slots) {
  const runsDir = path.join(support, `${slot}-run-archives`);
  let stamps = [];
  try { stamps = fs.readdirSync(runsDir).filter((n) => /^\d{8}-\d{6}$/.test(n)); } catch (e) { continue; }
  archivesSeen += stamps.length;
  for (const stamp of stamps.sort().reverse()) {
    const queueFile = path.join(runsDir, stamp, `overture-${slot}-queue.json`);
    let queue;
    try {
      queue = JSON.parse(fs.readFileSync(queueFile, "utf8"));
    } catch (e) {
      // An archived queue this tool cannot READ is a different answer from a show that is not in it,
      // and skipping it silently made them the same: the run vanished and the show came back as never
      // checked. That is the worse direction, because a run whose archive is damaged is exactly the one
      // somebody is asking about (L10, L11).
      unreadable.push(`${stamp} (${slot}): ${e.message}`);
      continue;
    }
    const items = Array.isArray(queue.items) ? queue.items : [];
    const item = items.find((i) =>
      String(i.naturalKey || "").toLowerCase().includes(needle) ||
      String(i.groupName || "").toLowerCase().includes(needle));
    if (!item) continue;
    hits.push({ slot, stamp, item, itemCount: items.length });
  }
}

// UNMEASURED before NOT FOUND, because they are different answers and only one of them is about the
// show (L98).
if (archivesSeen === 0) {
  console.error("UNMEASURED: no archived runs at all under " + support + ", so nothing could be read.");
  process.exit(2);
}
// Said BEFORE any verdict, because an unreadable run changes what "appears in no archived run" is
// worth: the show may well be in the one that could not be read.
if (unreadable.length > 0) {
  console.log(`${unreadable.length} archived run(s) could not be read, so this answer is incomplete:`);
  for (const u of unreadable) console.log(`  ${u}`);
  console.log("");
}
if (hits.length === 0) {
  console.log(`"${query}" appears in no archived run that could be read.`);
  console.log("Nothing was checked, or the run predates archiving.");
  process.exit(1);
}

// A web call, in the shape the stream records it. Only the routes that reach the WEB: a Read or a Bash
// that touches no network is not a search, and counting one would pad the list this exists to make
// readable.
const webCall = (name, input) => {
  if (name === "WebSearch") return `search  ${input && input.query}`;
  if (name === "WebFetch") return `fetch   ${input && input.url}`;
  if (name && name.startsWith("mcp__playwright__browser_navigate")) return `browser ${input && input.url}`;
  if (name === "Bash" && input && /https?:\/\//.test(String(input.command || ""))) {
    return `bash    ${input.command}`;
  }
  return null;
};

for (const hit of hits) {
  const i = hit.item;
  console.log(`=== ${hit.stamp} (${hit.slot} run, ${hit.itemCount} shows in the queue) ===`);
  console.log("");
  console.log("The show, as the run was GIVEN it:");
  for (const k of ["naturalKey", "groupName", "venue", "performanceDate", "presenterOnRecord",
                   "sourceListingURL", "onlyTheActIsNamed"]) {
    if (i[k] !== undefined && i[k] !== null) console.log(`  ${k}: ${i[k]}`);
  }
  console.log("");

  // #3357 Phase 1.3: the per item SIDECAR, if this run has one. It is what lets the calls be
  // attributed to THIS show rather than read as the whole chunk, which is the refusal printed at the
  // bottom of this block and the reason it was printed.
  //
  // Archived on its own longer rotation, 60 against the 10 kept for streams, so a run can
  // legitimately have a
  // sidecar and no streams. That is the good case: the derivation outlives the evidence it was made
  // from, on purpose, because nothing can re-derive it afterwards.
  let attributed = null;
  let killedChunks = [];
  try {
    const sidecar = JSON.parse(fs.readFileSync(
      path.join(support, `${hit.slot}-run-attribution-archives`, hit.stamp,
                `${hit.slot}-run-attribution.json`), "utf8"));
    killedChunks = (sidecar.watchdogKills || []).map((k) => k.chunk);
    for (const stream of sidecar.streams || []) {
      for (const item of stream.items || []) {
        if (item.naturalKey === i.naturalKey) {
          attributed = (item.calls || []).map(
            (c) => `${c.route === "search" ? "search " : "fetch  "} ${c.detail}`);
        }
      }
    }
  } catch (e) { attributed = null; }

  if (attributed !== null) {
    console.log(`Web calls this run made FOR THIS SHOW (${attributed.length}), from the run own`);
    console.log("per item attribution:");
    for (const c of attributed) console.log(`    ${c}`);
    if (attributed.length === 0) {
      console.log("    none. The run reached this show and searched for nothing.");
    }
    if (killedChunks.length > 0) {
      console.log("");
      console.log(`  Note: the stuck-request watchdog killed ${killedChunks.length} chunk(s) in this`);
      console.log("  run, so it is not usable as comparison evidence (#3007).");
    }
    console.log("");
    continue;
  }

  const streamsDir = path.join(support, `${hit.slot}-run-event-archives`, hit.stamp);
  let streams = [];
  try {
    streams = fs.readdirSync(streamsDir).filter((n) => n.endsWith(".jsonl")).sort();
  } catch (e) { streams = []; }

  if (streams.length === 0) {
    // The commonest state for anything older than #3446, and it is a fact about the EVIDENCE rather
    // than about the check. Saying "no searches" here would be a claim nobody measured (L11).
    console.log("Its searches: not archived for this run.");
    console.log("  The streams live at a fixed path and the next run overwrites them; they have only");
    console.log("  been kept per run since #3446, so a run from before that has none.");
    console.log("");
    continue;
  }

  for (const name of streams) {
    const calls = [];
    for (const line of fs.readFileSync(path.join(streamsDir, name), "utf8").split("\n")) {
      const t = line.trim();
      if (!t) continue;
      let o;
      try { o = JSON.parse(t); } catch (e) { continue; }
      if (!o || o.type !== "assistant") continue;
      for (const c of ((o.message || {}).content) || []) {
        if (c && c.type === "tool_use") {
          const rendered = webCall(c.name, c.input);
          if (rendered) calls.push(rendered);
        }
      }
    }
    console.log(`  ${name}: ${calls.length} web call(s)`);
    for (const c of calls) console.log(`    ${c}`);
  }

  // WHICH show a call belongs to is not established, and saying so is the point rather than a caveat.
  // Every surviving stream measured on 2026-08-30 held ONE show, so on those the attribution is the
  // whole chunk; a chunk covering several is where a per item sidecar is needed, which is Phase 1.3 of
  // milestone 61 and does not exist yet.
  if (hit.itemCount > streams.length) {
    console.log("");
    console.log("  Note: this run covered more shows than it has streams, so a stream carries several");
    console.log("  shows and these calls are NOT attributed to this one. Read them as the whole chunk.");
  }
  console.log("");
}
' "${SUPPORT}" "${QUERY}"
