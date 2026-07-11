# Spike #770: can we reliably extract show listings from an arbitrary org's website?

**Date:** 2026-07-11
**Question:** #768 (standing watchlist of sources) rests on an untested assumption: that we can pull
structured show listings out of an arbitrary performing-arts org's website. Carnegie is not evidence
(it hands us a clean Algolia JSON API). If extraction is unreliable, #768's design is wrong from the
start.

**Verdict: GO, but not the design the issue assumed.** Extraction itself is a solved problem. The
real risks sit either side of it: *finding* the listings page, *seeing* it at all, and *paying* for
it daily. Those are what #768 must be built around.

---

## Method

Seven real NYC-area org and presenter sites, chosen to cover the shapes Dan actually pitches. Each
page was fetched with a plain HTTP GET (no JavaScript), exactly as a URLSession-based scout would,
and the whole raw HTML handed to one Claude agent with a fixed prompt asking for the existing
`ExtractedEvent` shape (`mac/Overture/Domain/EventClassifier.swift:8`) and upcoming events only, as
of 2026-07-11.

Ground truth was established BY HAND from the rendered page, before extraction ran, so the model was
never grading its own homework.

Fetching this way was deliberate. Had the pages been pre-rendered in a headless browser, a
client-side ticketing widget would have looked like it worked perfectly, and #768 would have been
greenlit on a result the shipped scout could never reproduce.

## Results

| Site | Shape | Truth | Found | Missed | Made up | Verdict |
|---|---|---|---|---|---|---|
| Symphony Space | presenter, Spektrix, server-rendered | 12 | 12 | 0 | 0 | pass |
| Bargemusic | month-grid calendar, date implied by cell | 6 | 6 | 0 | 0 | pass |
| Musica Sacra | WordPress, listings only in a nav menu | 6 | 6 | 0 | 0 | pass |
| Chelsea Symphony | orchestra, Eventbrite links | 0 | 0 | 0 | 0 | pass (correctly empty) |
| NY Choral Society | choir season page | 0 | 0 | 0 | 0 | pass (correctly empty) |
| Heartbeat Opera | small opera, Squarespace | 0 | 0 | 0 | 0 | pass (correctly empty) |
| Third Street Music School | music school, JS-rendered calendar | n/a | 0 | n/a | 0 | blind (see below) |

**Nothing was missed and nothing was invented, across every site.** It passed the traps:

- **Bargemusic** prints no dates at all: concerts sit in cells of a month grid, and the date is
  implied by cell position. It reconstructed all six, and correctly dated the two trailing cells as
  **August 1 and 2** rather than July 1 and 2 (which would have been in the past). It also reported,
  unprompted, that only one month is visible per fetch and that the venue exists in the markup only
  as a numeric ID.
- **Chelsea Symphony** is the sharpest false-positive trap in the sample: eleven concert dates sit on
  the page under the heading "Previous Concerts This Season". A naive extractor reports seven
  upcoming shows that do not exist. It returned none, and named the reason.
- **Heartbeat Opera**'s calendar says "There are no upcoming events at this time." It did not invent
  a season from the surrounding marketing copy.
- **Musica Sacra**'s upcoming shows appear only in a nav dropdown, with no years. It inferred the
  years from season ordering, and I verified two by hand against the event pages: October 7 **2026**
  and March 23 **2027** were both right.

## What actually threatens #768

Extraction accuracy is not the risk. These four are.

**1. Finding the listings page is its own problem.** Guessing the URL by convention fails badly:
`musicasacrany.com/concerts` is a **2021 archived concert**, not a listings page, and
`thirdstreetmusicschool.org/events` redirects to a homepage on a different domain. Both look like
success (HTTP 200, plenty of dates in the HTML) while being the wrong page. A source's listings URL
must be discovered once and recorded explicitly, and ideally confirmed by Dan, never re-guessed per
run.

**2. Some calendars are invisible to a raw fetch.** Third Street's events load client-side from an
external widget: its raw HTML contains no event data whatsoever, so a URLSession scout can never see
them, no matter how good the model is. This affected 1 of 7 sites. It needs a headless-browser
fallback, but only as a fallback (see the recommendation below).

**3. The listings page usually does not carry the venue, and sometimes not the year.** Bargemusic
exposes only numeric venue IDs; Musica Sacra's nav gives neither venue nor year. Both are stated
plainly on each event's own detail page. Overture needs the venue (it drives the classifier and
Dan's whole pitch), so the extractor must follow the event link rather than infer. The year
inference happened to be right here; that is not something to depend on when the detail page states
it outright.

**4. Off-season is the normal state, and stale seasons look current.** Five of seven sites had
**zero** upcoming shows on 2026-07-11: small orgs have not posted their 26-27 seasons yet, and their
sites still show last season's dates. This matters twice over. A watchlist will return nothing for
weeks at a time, which is correct behavior and must not be mistaken for a broken scout. And the
"upcoming only" filter is load-bearing: without it, the very first run would flood the queue with
concerts that already happened.

## Cost

Sending whole raw pages costs roughly **15k to 46k input tokens per site, per check** (~25k average;
177k for the seven). At a daily re-check that is ~500k tokens/day for only 20 watched sources,
almost all of it spent re-reading pages that have not changed.

**The single biggest cost lever: store a content hash (or ETag) per source and skip the AI call
entirely when the page has not changed.** Org sites change a few times a season. This likely cuts
the recurring cost by an order of magnitude and should be in the design from the start, not added
later.

## Recommended design changes for #768

1. **Record each source's listings URL explicitly** (discovered once, confirmed by Dan). Never guess
   it by convention per run: that lands on 2021 archives.
2. **Fetch raw HTTP first; fall back to a headless render only when the raw page yields no dated
   listings.** Only 1 of 7 needed it, so the expensive path stays rare.
3. **Follow each event's own detail page** for the venue and the exact date, rather than inferring
   them from the listing.
4. **Hash the page and skip extraction when unchanged.** This is the cost model, not an optimization.
5. **Handle pagination** (Bargemusic shows one month per fetch).
6. **Expect long empty stretches.** "Found nothing" is the normal summer answer, not a failure.

## One thing extraction cannot fix

Symphony Space's twelve upcoming events are almost entirely film screenings, NT Live broadcasts and
literary talks: extraction succeeded completely, and produced almost nothing Dan would photograph. A
watchlist widens the funnel, but the classifier and ranker decide whether that funnel is worth
anything. Watching more sources will surface more junk as well as more leads, and #768 should be
judged on qualified leads, not on shows found.

## Refs

- Blocks: #768. Related: #771 (record which source surfaced each prospect), #386.
- Target shape: `mac/Overture/Domain/EventClassifier.swift:8`
- Why Carnegie is not representative: `mac/Overture/Integration/AlgoliaCalendar.swift`
