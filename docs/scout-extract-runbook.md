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
   ("Weill Recital Hall"). A location is the place ("New York, NY"). Measured on the live store, **0 of
   26 distinct venue strings contain a city at all**, so a venue can never answer "where is this".

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

   Never follow a link to another listings page (`/P20`, `?page=2`, "next month") yourself. That rule has
   not changed and the reason has not either: the app fetched and hashed the bytes it handed you, so
   anything you wander off to find is not part of the set it reconciles against, and a run that wanders
   across an unbounded number of pages is the one that never comes back. (Following each EVENT's own
   detail page for its venue and date is a different thing, and is still required.)

   Why the app does the walking: Kaufman's calendar shows only the month you land on. In July that is 6
   shows, while August, September and October hold 30 more, and those later months are the pitchable
   ones. The app reads four months and stitches them, so the listing set still comes from bytes the app
   fetched and hashed.

6. **Update the progress file** after each item, so the app can show "3 of 9" rather than a spinner.

## The rule that lost twenty shows

**Always write the results file before you finish. A question is not an output.**

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

## Files

| file | who writes it |
|---|---|
| `overture-scout-extract-queue.json` | the app |
| `overture-scout-extract-results.json` | this run |
| `overture-scout-extract-progress.json` | the script seeds it, this run updates it |
| `overture-scout-page-<sourceId>.html` | the app (the pinned page you read) |
| `scout-extract-run.log` | the script (shown to Dan when a run finishes empty) |

The pinned page and any `.corrupt` results file are swept by the app at launch once they are more than
14 days old (`HandoffCleanup`, #821). Recent ones stay, deliberately: they are the only record of what
a run actually read and what it produced when something went wrong.

## Tools

`--allowedTools "Read,Write,WebFetch"`. No `Bash`, no `Skill`, no `WebSearch`: this run reads files,
follows links it was handed, and writes two files. `reply-classify-run.sh` already ships the tighter
`"Read,Write"` grant; only `prep-run.sh` needs a wide one.
