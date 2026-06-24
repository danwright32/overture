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

A `Lost` row is soft by default. To mark one a hard "never", add an optional **`Lost reason`**
column to the sheet and write a reason that reads as a hard no (it counts as hard when the cell
starts with "hard" or contains "never" or "not interested"). The column is optional; with no such
column every `Lost` row imports as soft.
