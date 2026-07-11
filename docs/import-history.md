# Importing pre-Overture booking history (one time)

Overture knows the orgs it has emailed plus the Downbeat client list. To also recognize
years of pre-Overture outreach (past contacts, warm relationships, do-not-contact entries),
import Dan's booking-log CSV once. The app merges this with its own live activity at scout
time, so it never goes stale.

## Run it

Run from the `Overture/` project folder (the one with `package.json`), on one line:

```
cd "/path/to/Marketing/Outreach/Overture" && pnpm import-history "/path/to/Lead Booking sources - 2026 Bookings.csv"
```

This parses the CSV and writes `~/Library/Application Support/Overture/overture-history.json`
(the same handoff folder the results and blocked-dates files live in). It overwrites the file,
so re-running with an updated CSV is safe.

## How rows map to ranking signals

Each row becomes one history record, scored by the relationship ladder. The mapping reads the
`Status` and `First Contact` columns (see `src/lib/bookingImport.ts`):

| Sheet value | App status | Effect |
| --- | --- | --- |
| `Status = Booked` | `booked` | Strong boost (past client) |
| `Status = I Declined` | `declined` | Hot lead (Dan passed, usually a date conflict) |
| `First Contact = Warm Email (…)` | `warm` | Boost (referral / prior interest); beats a Lost outcome |
| `Status = Lost` (soft / blank reason) | `lost_soft` | Small boost (door open) |
| `Status = Lost` + hard reason | `lost_hard` | Heavy penalty, stays visible |
| `Status = DNC` | `dnc` | Removed from results |
| Cold pitch + `No Response` | (dropped) | Neutral, no record kept |

## The `Email` column (#762)

The sheet's **`Email`** column now rides along into `overture-history.json` as an optional `email`
field on each record. It is what lets Overture confirm a performer-name match: when a show's
performer is matched by name to a past booking, a matching address corroborates it, and a
CONFLICTING address suppresses the match entirely, because two different people share a name far
more often than one person changes their address.

That matters most here rather than for the Downbeat client list, because the booking history is
older and broader, so a name hit in it is the one most likely to be a different person who merely
shares the name. A blank cell is simply no signal, and the name alone decides. One cell may hold two
addresses (the sheet really is written that way); either one corroborates.

**Existing files keep working**: the field is additive and optional, so an `overture-history.json`
written before this change still loads. But the addresses only start doing anything once the import
is re-run, since an older file has none in it.

A `Lost` row is soft by default. To mark one a hard "never", add an optional **`Lost reason`**
column to the sheet and write a reason that reads as a hard no (it counts as hard when the cell
starts with "hard" or contains "never" or "not interested"). The column is optional; with no such
column every `Lost` row imports as soft.
