# Scout-extract runbook

The detached Claude Code run that reads a watched source's listings page and hands back the upcoming
performances (#799). The app launches it; nobody supervises it.

This run is a workflow, not Swift, so it has **no automated test**. This runbook plus
`fixtures/scout-extract/` is its spec. `docs/contracts.md` catalogs the three files it exchanges.

## Setup (one time)

Overture finds this script through a stored setting. Until that is set, the feature is unavailable and
says so in words ("The scout-extract runner isn't set up yet"), never silently.

1. Make the script executable:

```
chmod +x "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac/scripts/scout-extract-run.sh"
```

2. Point Overture at it:

```
defaults write com.danwright.overture scoutExtractRunnerScriptPath "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac/scripts/scout-extract-run.sh"
```

3. **The Debug build needs its own copy of that setting.** Debug and Release have different bundle
   identities, so `UserDefaults.standard` resolves to a DIFFERENT preferences domain in each, and the
   command above configures the Release app only. Launch the Debug build (which is the only safe way to
   try a change: `mac/scripts/run-debug.sh`) and the feature reports "the runner isn't set up", for no
   visible reason. Nothing is broken; it is looking somewhere else.

```
defaults write com.danwright.overture.debug scoutExtractRunnerScriptPath "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac/scripts/scout-extract-run.sh"
```

## What the run does

The app has already fetched each page, normalized it, hashed it, and written it to disk. **The run does
not fetch the listings page.** It reads the pinned copy it is pointed at.

That split is not a detail. The listing SET (which shows exist, which have gone) is what re-keys
prospects and drives the "was this cancelled?" reconcile, so it must come from bytes the app hashed,
not from whatever the site served the agent a second later.

For each item in the work-list:

1. **Read the pinned page** at `pagePath`. It is normalized HTML: scripts, styles and attribute noise
   are stripped, but the tag structure (**including tables and cells**) and links are intact.

   Read the grid. Some calendars print no dates at all: Bargemusic puts each concert in a cell of a
   month grid, so the date is implied by *which cell* it sits in plus the month heading. Trailing cells
   often belong to the NEXT month (a July grid's last two cells are August 1 and 2). Get that wrong and
   a real show is dated into the past and silently dropped.

   **If one read does not return the whole file** (the tool says there is more, or offers an offset to
   continue), keep reading with an increasing offset until the entire file is covered, before extracting
   or judging anything. A large calendar (#1012: FRIGID's page, 26KB) can be bigger than a single read
   returns, and stopping at the first chunk is exactly what turned a healthy `upcoming_listings` verdict
   into a silent loss: dozens of real shows never seen, and the source's content hash latched as if the
   whole page had been read, so nothing ever asked again. Only report `incomplete_extraction` (below)
   after actually trying to read the rest of the file this way.

2. **Extract every upcoming performance.** Today or later. Never invent one that is not on the page.

   **If the item carries `onlyForOrg`, return ONLY that organization's performances.** Everything else
   on the page is somebody else's show, however real it looks.

   This is not hypothetical. The app sets `onlyForOrg` when it had to follow a link off an org's own
   site (unreadable) onto a VENUE's page, and a venue page is a page about many organizations. Lincoln
   Center's page for one ensemble's concert also carries an "Alice Tully Hall upcoming events" sidebar.
   A run that returned those handed Dan four concerts that were real, at the right hall, and presented
   by the Chamber Music Society and Lincoln Center Presents: not the org he was tracking at all.

   If the org's own concert on that page has already happened, the honest answer is that they have
   nothing upcoming. Say so in the `note` and return no events. Do NOT reach for the hall's other shows
   to have something to return.

   **"Never invent one" covers the FIELDS of a real event, not just the event** (#995). A row that is
   genuinely on the page does not entitle you to fill in the parts of it the page left blank. Report what
   the page says and leave the rest null.

   The real case: a page listed a date whose title read only *"Info coming soon"*. The run returned it as
   `Palm Springs Engagement`, a phrase that appears nowhere on the page, and noted "Oct 24 event title
   inferred". No code can catch this: an invented title is indistinguishable from a real one to
   everything downstream, and it becomes half of how Overture recognises that show again on the next
   scout (#797). A `note` admitting the invention does not license it, because the title is what Dan
   reads and the note is not.

3. **Follow each event's own link** (`WebFetch`) for the **venue** and the **exact date**. The listings
   page usually carries neither, and Overture needs the venue: it drives classification and the pitch
   itself. Never guess a venue.

   **An event without a real venue is DROPPED.** This is enforced in code (`ExtractedEventGuard`), not
   merely asked for here, so skipping this step does not produce slightly-worse events: it produces
   *no* events, and the source is reported as one whose detail pages are not being read.

   The reason is Bargemusic, and it is not hypothetical. Its listings page names no venue at all: each
   concert carries a numeric venue id. Following the detail page yields "Brooklyn Bridge Park Boathouse
   at Pier 5, Brooklyn, NY", and the concert is not even on the barge. Take the venue from the listing
   and every pitch names the wrong place, with nothing downstream able to notice.

   **A null venue is a RIGHT answer, not a lost row** (#995). Read the paragraph above as a fact about
   what a venue is for, never as pressure to produce one. Some pages publish no venue anywhere, for any
   event, and never will: on those, null on every row is the correct and complete result, and the run
   has succeeded. Reporting that honestly is worth more to Dan than a full-looking list, because he is
   deciding what to do about those sources and can only do it if the file says what is really there.

   So: if a page does not name the venue, say so in the `note` and leave `venue` null. Do not invent one,
   do not pass through a numeric id, "TBD" or "unknown", and **never copy the location into `venue`**.
   A city is not a room. `location` (3a) is where that fact belongs, and it has its own field precisely
   so `venue` never has to absorb it.

   **A specific, NAMED outdoor performance space IS a venue** (#1057), even though it is not a room. Dan's
   call: the pitch email can say "your Oct 25 concert at Sakura Park" the same way it says "at Carnegie
   Hall," so a named park, plaza, or pier belongs in `venue`, not `location`. The distinction is between a
   place with its own proper name and a bare location string that only says where the city is:

   | what the page says | report `venue` as | report `location` as |
   |---|---|---|
   | `Sakura Park, W 122nd St & Riverside Dr` | `Sakura Park, W 122nd St & Riverside Dr` | (verbatim, per 3a, even though it repeats the venue name) |
   | `Golden Hour Series at Greeley Square` | `Greeley Square` | whatever the page states, if anything |
   | `downtown Brooklyn, NY` | `null` (this names no specific place) | `downtown Brooklyn, NY` |
   | `Baltimore, Maryland` | `null` (a city is not a venue) | `Baltimore, Maryland` |

   If in doubt whether a place is specific enough to be a venue, ask: could Dan's pitch name it the way it
   names a hall? "Bryant Park" and "Pier 5" pass that test. "Brooklyn" and "the waterfront area" do not.

   This last one is not hypothetical either, and it is why this paragraph exists. The first real scout of
   a venue-less page returned `venue: "Baltimore, Maryland"`, `venue: "Harrogate, UK"`, and two more like
   them, explaining itself in the note: *"Venue field populated with location as best available
   specificity."* Every one of those is now rejected as `no venue (the listing gave only a place)`, so
   the disguise buys nothing. It is worse than null, because a null says "this page has no venues" and a
   city in the venue field says "Dan's email should offer to photograph Baltimore, Maryland".

3a. **Report `location`: where the show is, VERBATIM, exactly as the page wrote it** (#970). Copy the
   string across untouched. Do not tidy it, expand it, abbreviate it, or translate it into a format you
   think is cleaner. Judging what a location MEANS is Overture's job, not yours; your job is to hand
   over what the page actually said, unedited.

   This is not the same field as `venue`, and one cannot substitute for the other. A venue is the room
   ("Weill Recital Hall") or a specific named outdoor place (#1057: "Sakura Park"). A location is the
   place ("New York, NY"). A venue can still end up carrying a city when a source page bakes a full
   street address into it (#1030: "The Players Theatre, 115 MacDougal Street, New York, NY"), but that
   is an artifact of the address, not a location report, and the display layer strips it back out
   (`VenueDisplay`). **`venue` cannot be relied on to always name a city**, so `location` is still the
   dedicated field for it, and reporting it (3a) is never optional just because `venue` happened to.

   Take it from wherever the page puts it. Many artist and ensemble sites carry a location field of
   their own, separate from the title and the venue, and some name **no venue anywhere**, only a city.
   Real examples, all verbatim, all of which must survive exactly as written:

   | what the page says | report `location` as |
   |---|---|
   | `New York, NY` | `New York, NY` |
   | `Louisville, KY` | `Louisville, KY` |
   | `Baltimore, Maryland` | `Baltimore, Maryland` (do NOT shorten to MD) |
   | `Harrogate, UK` | `Harrogate, UK` |
   | `Amsterdam` | `Amsterdam` (do NOT add a country) |
   | `southern Norway` | `southern Norway` (a region is not a city; report it anyway) |
   | `Orange County, Santa Barbara, Pasadena, and Santa Monica` | the whole string, unedited |
   | `26 Thorwaldsenstraße Berlin, BE, 12157 Germany` | the whole address, unedited |

   **If the page names no location, leave it null.** That is common and is not a failure: it means the
   page did not say, and Overture treats an unknown place as a show to keep and flag for Dan, never as
   one to hide. Guessing a city from an org's name, a hall you recognise, or the site's home country is
   worse than null, because a confident wrong place is the one thing that can hide a real show.

   Unlike `venue`, a missing `location` does **not** drop the event.

4. **Judge the page and report one verdict.** This is the part that matters most, because an empty
   event list is ambiguous and all three readings occur in the wild:

   | verdict | means |
   |---|---|
   | `upcoming_listings` | it has upcoming performances, and you are returning them |
   | `all_past` | it has dated listings, but every one has already happened. **A normal, healthy state**: an org between seasons. In July, 5 of the 7 real sites tested were exactly this. Report it honestly rather than reaching for something to return. |
   | `no_dated_content` | no dated listings at all. Usually the WRONG page (guessing a URL by convention lands on a 2021 archive that answers HTTP 200). |
   | `unreadable` | the bytes carry no event data: a calendar drawn by JavaScript, or a login wall (an Instagram link does this). Say so. Do not pretend to have read it. |
   | `incomplete_extraction` | the page is larger than could be read even after paging through it with an increasing offset (step 1). Return whatever events turned up in the part actually read, and say in the note that the page was too large to finish. This is the ONLY verdict where a real, non-empty event list and an honest admission of missing more both belong together. |

   A quiet source and a broken source must never look the same to Dan. The verdict is the only thing
   that tells them apart. Nor may a partially read source look like a fully read one: `incomplete_extraction`
   keeps whatever it found (unlike the other three failure verdicts, which return nothing), but it never
   lets the app treat this page as finished, so the next scout goes back for the rest.

5. **Pagination: never follow a listings link; read every month the app already fetched.** The app walks
   a calendar's own month index itself (#858) and hands you the result, so a pinned page may hold
   SEVERAL months, each wrapped in a section under a marker naming it:

   ```
   <!-- overture-month 2026-10 https://example.org/calendar/2026/10/ -->
   ```

   Read every marked section and return the shows from all of them as one set under that one `sourceId`.
   Do not stop at the first, and do not report "page 1 of N".

   **Report which months you read in `monthsCovered`** (#897): the list of month labels from the markers
   of every section you actually read, for example `["2026-07", "2026-08", "2026-09", "2026-10"]`. This
   is not bookkeeping. The app fetched and stitched those months and knows exactly which ones it handed
   you; if `monthsCovered` is missing any of them, the app treats the read as incomplete rather than as a
   smaller calendar, keeps whatever shows you found, and reads the page again next scout instead of
   trusting its silence about the months you skipped. A stitched page whose sections you did not all read
   is the one way this step can quietly cancel a live show, so report honestly: list a month only if you
   read its section, and list every month you did. On a single-section (one-month) page, omit the field.

   Never follow a link to another listings page (`/P20`, `?page=2`, "next month") yourself. That rule has
   not changed and the reason has not either: the app fetched and hashed the bytes it handed you, so
   anything you wander off to find is not part of the set it reconciles against, and a run that wanders
   across an unbounded number of pages is the one that never comes back. (Following each EVENT's own
   detail page for its venue and date is a different thing, and is still required.)

   Why the app does the walking: Kaufman's calendar shows only the month you land on. In July that is 6
   shows, while August, September and October hold 30 more, and those later months are the pitchable
   ones. The app reads four months and stitches them, so the listing set still comes from bytes the app
   fetched and hashed.

6. **Rewrite the results file immediately after finishing each item**, not only once at the very end.
   Every write is the COMPLETE v1 ScoutExtractResults JSON covering everything finished so far, not
   just the item you just did. The last time you do this simply is the end of the run.

   #1015: the app derives "3 of 9" for the toolbar by counting entries in this file itself, on a
   timer, so you are never asked to report a count directly. On 2026-07-16 a run never touched a
   separate progress file even once, and the toolbar sat at "0 of 20" through a run that was doing
   real work. Writing results incrementally is what fixes that: the app's count can only ever be as
   current as what is actually on disk, so keeping this file current after every item is what keeps
   Dan's toolbar honest.

## The rule that lost twenty shows

**Always have written the results file, covering every item, before you finish. A question is not an
output.**

This run is DETACHED. Nobody is reading its output and nobody can answer it. On 2026-07-12 it read a
paginated Kaufman Music Center page, extracted 20 events correctly, and then stopped to ask which of two
things it should do about the further pages. Nobody was there. It exited having written nothing, twenty
correct extractions were thrown away, and the app sat polling for a file that would never arrive.

So: never stop to ask. Decide, do it, and record the decision in the `note`. A result with a verdict and
an honest note is worth everything. A question is worth nothing, because the work does not survive it.

## The one rule that silently loses work

**`sourceId` is opaque. Echo it back verbatim. Never rebuild it.** A reconstructed id matches nothing
on the way home, so the events are dropped with no error anywhere. `fixtures/prep-queue/` carries the
same rule for the same reason.

## How the run is split (#1028)

Sonnet reads every page and follows each event's detail link, which is accurate but slow: a 2026-07-17
run took 16 minutes for 18 sources, entirely sequential, a bare opaque wait on something Dan started by
hand. The sources are independent until the app reconciles them, so the script splits the work-list into
up to `SCOUT_EXTRACT_MAX_PARALLEL` (default 4) contiguous chunks and drives one claude per chunk at the
same time, cutting the wait roughly in proportion to the chunk count.

This is invisible to the app and to the model. The app still writes one queue, polls one progress file,
and ingests one results file, all in the same shapes. Each chunk is a partition, so every `sourceId`
lands in exactly one chunk; each chunk's claude reads only its own chunk queue and writes only its own
chunk results file (never a shared one, which concurrent incremental rewrites would clobber). The
prompt is unchanged per chunk: only the two paths it names are swapped for that chunk's files.

The script's heartbeat merges the per-chunk results into the one results file every tick, so the derived
"N of M" count advances across all chunks at once, and the final merge runs once more after every chunk
exits. Because the merge feeds the same results file the results guard checks against the FULL queue, a
chunk whose process dies writing nothing does not lose its sources: the script reports each one as a run
that came back with nothing for it, exactly as it would for a lost sequential run (`lib/results-guard.sh`
speaks for the sources, the same guard that has always closed this hole). Set `SCOUT_EXTRACT_MAX_PARALLEL=1`
to fall straight back to a single sequential process. The split and merge are `lib/scout-parallel.sh`, the
only part with an automated test (`lib/scout-parallel.test.sh`), because a partition that dropped a
source or a merge that lost one would be a silent loss of Dan's shows.

## Stopping a run (#1037)

A scout Dan started can be cancelled from its progress window. The read is detached and has no trackable
PID (the app backgrounds it via `sh -c '... &'` and keeps no handle), so there is nothing to `kill`.
The stop is COOPERATIVE instead: the app writes an empty sentinel file, `scout-extract-cancel`, into the
handoff dir, and the script's heartbeat checks for it. The heartbeat reads the sentinel on a SHORT poll
(`SCOUT_EXTRACT_CANCEL_POLL_SECONDS`, default 3), decoupled from the 60s marker work it also does
(touching the marker, merging the per-chunk results, and deriving the count, gated behind `marker_due`),
so a Cancel Dan clicks stops the read (and its token spend) within a few seconds instead of up to a
minute (#1053). The 60s work's cost is unchanged; only the cancel latency drops. When the sentinel is
there, the heartbeat stops the chunk processes it recorded in `scout-extract-chunk-pids` and exits; the
main script's `wait` then returns and it exits through its normal cleanup, so `lib/results-guard.sh`
still speaks for every source and whatever landed is ingested.

Cooperative, not instant, on purpose: the kill lands at a poll boundary and never during the merge (which
runs only on the marker branch), so it can never interrupt a source mid-write and corrupt the shared
results file the way a `kill -9` could. The sentinel's PRESENCE is the request; its contents are never
read. The script clears it on exit (`lib/scout-cancel.sh`'s
`clear_cancel`), and the app clears any stale one before starting a fresh run, so a sentinel left over
from a cancelled run can never stop the next one. See `docs/contracts.md` for the cross-language contract.

## Files

| file | who writes it |
|---|---|
| `overture-scout-extract-queue.json` | the app |
| `scout-extract-cancel` | the app, to ask a running read to stop (#1037); the script reads its presence on each heartbeat and clears it on exit |
| `scout-extract-chunk-pids` | the script, so its heartbeat knows which chunk processes to stop on a cancel (#1037); wiped every run |
| `overture-scout-extract-results.json` | the script, merged from the per-chunk results every heartbeat and once at the end (#1028); each chunk's claude rewrites its own chunk file after every item, not only at the end (#1015) |
| `overture-scout-extract-progress.json` | the script only, seeded and then continuously derived from the results file above; this run never writes it (#1015) |
| `scout-extract-chunks/chunk-queue-<n>.json`, `chunk-results-<n>.json` | the script's scratch dir (#1028): the split queue each chunk reads and the results each chunk writes, wiped and rebuilt every run; the app never reads these |
| `overture-scout-page-<sourceId>.html` | the app (the pinned page you read) |
| `scout-extract-run.log`, `scout-extract-run.chunk-<n>.log` | the script (the main log, shown to Dan when a run finishes empty, plus one log per chunk whose tail is folded into it) |

The pinned page and any `.corrupt` results file are swept by the app at launch once they are more than
14 days old (`HandoffCleanup`, #821). Recent ones stay, deliberately: they are the only record of what
a run actually read and what it produced when something went wrong.

## Tools

`--allowedTools "Read,Write,WebFetch" --permission-mode manual` (built from `lib/scout-tools.sh`, #1026).
This run reads files, follows links it was handed, and writes two files, nothing else. `Bash`, `Edit`,
`Skill` and `WebSearch` are genuinely unreachable, not merely un-listed: `--allowedTools` on its own only
PRE-APPROVES the three named tools, and a detached `claude -p` inherits `~/.claude` settings where
`permissions.defaultMode` is `auto`, which auto-approves every other tool too (a 2026-07-17 run made 13
`Bash` and 14 `Edit` calls with no denials). `--permission-mode manual` overrides that inherited auto, so
anything outside the allowlist needs an approval the detached run cannot give and is denied. If the scope
is ever edited into an unsafe posture (an auto-approving mode, or a forbidden tool in the allowlist) the
runner refuses to start rather than silently regaining a shell. `reply-classify-run.sh` and `prep-run.sh`
still carry the older `--allowedTools`-only posture (prep deliberately wants `Bash`/`Skill` for the
brand-voice skill); tightening those the same way is tracked separately.
