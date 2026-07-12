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

2. **Extract every upcoming performance.** Today or later. Never invent one that is not on the page.

3. **Follow each event's own link** (`WebFetch`) for the **venue** and the **exact date**. The listings
   page usually carries neither, and Overture needs the venue: it drives classification and the pitch
   itself. Never guess a venue.

4. **Judge the page and report one verdict.** This is the part that matters most, because an empty
   event list is ambiguous and all three readings occur in the wild:

   | verdict | means |
   |---|---|
   | `upcoming_listings` | it has upcoming performances, and you are returning them |
   | `all_past` | it has dated listings, but every one has already happened. **A normal, healthy state**: an org between seasons. In July, 5 of the 7 real sites tested were exactly this. Report it honestly rather than reaching for something to return. |
   | `no_dated_content` | no dated listings at all. Usually the WRONG page (guessing a URL by convention lands on a 2021 archive that answers HTTP 200). |
   | `unreadable` | the bytes carry no event data: a calendar drawn by JavaScript, or a login wall (an Instagram link does this). Say so. Do not pretend to have read it. |

   A quiet source and a broken source must never look the same to Dan. The verdict is the only thing
   that tells them apart.

5. **Update the progress file** after each item, so the app can show "3 of 9" rather than a spinner.

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

## Tools

`--allowedTools "Read,Write,WebFetch"`. No `Bash`, no `Skill`, no `WebSearch`: this run reads files,
follows links it was handed, and writes two files. `reply-classify-run.sh` already ships the tighter
`"Read,Write"` grant; only `prep-run.sh` needs a wide one.
