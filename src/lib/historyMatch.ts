// Produces the repeat-client verdict for a discovered performance by matching its
// group name against the canonical Downbeat clients (booked) and the imported CSV
// history (contacted / DNC-suppression). Confident matches set the score; a fuzzy
// match becomes a "possible" flag for Dan to confirm, never scored.

import type { DownbeatClient } from "./downbeatBridge";
import type { HistoryRecord } from "./bookingImport";
import { isConfidentMatch, isPossibleMatch } from "./groupNameMatch";

export type PossibleMatch = {
  source: "downbeat_client" | "history";
  ref: string;
  name: string;
};

export type MatchVerdict = {
  relationship: "booked" | "contacted" | "none";
  suppressed: boolean;
  downbeatClientId: string | null;
  matchedClientName: string | null;
  possible: PossibleMatch | null;
};

function clientNames(c: DownbeatClient): string[] {
  return c.shortName ? [c.displayName, c.shortName] : [c.displayName];
}

function isBooked(status: string | null): boolean {
  return (status ?? "").trim().toLowerCase() === "booked";
}

function isDnc(status: string | null): boolean {
  return (status ?? "").trim().toLowerCase() === "dnc";
}

export function matchRelationship(
  name: string,
  clients: DownbeatClient[],
  history: HistoryRecord[],
): MatchVerdict {
  const confidentHistory = history.filter((h) =>
    isConfidentMatch(name, h.group_name),
  );

  if (confidentHistory.some((h) => isDnc(h.status))) {
    return {
      relationship: "none",
      suppressed: true,
      downbeatClientId: null,
      matchedClientName: null,
      possible: null,
    };
  }

  const confidentClient =
    clients.find((c) => clientNames(c).some((n) => isConfidentMatch(name, n))) ??
    null;

  const historyBooked = confidentHistory.some((h) => isBooked(h.status));

  if (confidentClient || historyBooked) {
    return {
      relationship: "booked",
      suppressed: false,
      downbeatClientId: confidentClient ? confidentClient.id : null,
      matchedClientName: confidentClient ? confidentClient.displayName : null,
      possible: null,
    };
  }

  if (confidentHistory.length > 0) {
    return {
      relationship: "contacted",
      suppressed: false,
      downbeatClientId: null,
      matchedClientName: null,
      possible: null,
    };
  }

  const possibleClient = clients.find((c) =>
    clientNames(c).some((n) => isPossibleMatch(name, n)),
  );
  if (possibleClient) {
    return {
      relationship: "none",
      suppressed: false,
      downbeatClientId: null,
      matchedClientName: null,
      possible: {
        source: "downbeat_client",
        ref: possibleClient.id,
        name: possibleClient.displayName,
      },
    };
  }

  const possibleHistory = history.find((h) => isPossibleMatch(name, h.group_name));
  return {
    relationship: "none",
    suppressed: false,
    downbeatClientId: null,
    matchedClientName: null,
    possible: possibleHistory
      ? { source: "history", ref: "", name: possibleHistory.group_name }
      : null,
  };
}
