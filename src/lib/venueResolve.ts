// Resolves a discovered performance's venue against Downbeat's known venues by
// normalized name, recovering address and notes that feed the reachability and
// travel estimate. Returns null when the venue is unknown to Downbeat.

import type { DownbeatVenue } from "./downbeatBridge";
import { normalizeGroupName } from "./groupNameMatch";

export function resolveVenue(
  venueName: string | null,
  venues: DownbeatVenue[],
): DownbeatVenue | null {
  if (!venueName) return null;
  const target = normalizeGroupName(venueName);
  if (target === "") return null;
  return venues.find((v) => normalizeGroupName(v.name) === target) ?? null;
}
