// Reads Downbeat's local client/venue export (the bridge file Downbeat writes).
// Pure parsing is split from the file read so it can be tested with fixtures.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type DownbeatClient = {
  id: string;
  displayName: string;
  shortName: string | null;
  email: string;
  contractEmail: string;
  phoneNumber: string | null;
  isTaxExempt: boolean | null;
  hasLeftReview: boolean;
  specialBehaviors: string[];
  notes: string | null;
  hostingSite: string;
};

export type DownbeatVenue = {
  id: string;
  name: string;
  address: string | null;
  editingProfile: string | null;
  specialBehaviors: string[];
  staffNotificationEmails: string[];
  notes: string | null;
};

// One committed Downbeat booking. Dates are yyyy-MM-dd day strings (not timestamps).
// venueId is absent (not null) for an ad-hoc venue, so match on venueName then. For
// per-event booking detection (#99) key the org on clientId, never clientDisplayName.
export type DownbeatBooking = {
  id: string;
  clientId: string;
  clientDisplayName: string;
  shootName: string;
  startDate: string;
  endDate: string;
  venueId?: string;
  venueName: string;
};

export type DownbeatExport = {
  clients: DownbeatClient[];
  venues: DownbeatVenue[];
  // Committed bookings (#99 per-event detection). Empty before export version 2.
  bookings: DownbeatBooking[];
  // Calendar days (ISO yyyy-MM-dd) Dan is already booked; the scout suppresses
  // performances on these. Added in export version 2 (downbeat#52); a version-1
  // file has none, so the set is empty and the scout runs without date-blocking.
  // Note: entries may include past days (downbeat#53), so don't assume all upcoming.
  blockedDates: Set<string>;
};

const SUPPORTED_VERSIONS = new Set([1, 2]);

export function parseDownbeatExport(json: string): DownbeatExport {
  const data = JSON.parse(json) as {
    version?: number;
    clients?: DownbeatClient[];
    venues?: DownbeatVenue[];
    bookings?: DownbeatBooking[];
    blockedDates?: string[];
  };
  if (data.version === undefined || !SUPPORTED_VERSIONS.has(data.version)) {
    throw new Error(
      `Unsupported Downbeat export version: ${String(data.version)}`,
    );
  }
  return {
    clients: data.clients ?? [],
    venues: data.venues ?? [],
    bookings: data.bookings ?? [],
    blockedDates: new Set(data.blockedDates ?? []),
  };
}

const DEFAULT_EXPORT_PATH = join(
  homedir(),
  "Library",
  "Application Support",
  "Overture",
  "downbeat-export.json",
);

export function loadDownbeatExport(path = DEFAULT_EXPORT_PATH): DownbeatExport {
  return parseDownbeatExport(readFileSync(path, "utf8"));
}
