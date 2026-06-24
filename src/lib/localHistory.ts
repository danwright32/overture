// Reads the local booking-history file the importer (#69/#95) and the Mac app share,
// ~/Library/Application Support/Overture/overture-history.json. The file uses the app's
// camelCase shape ({ groupName, status }); the scout's matcher reads snake_case
// ({ group_name, status }), so this maps between them. Pure parsing is split from the
// file read so it can be tested with fixtures, mirroring downbeatBridge.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { HistoryMatch } from "./historyMatch";

type AppHistoryRecord = { groupName: string; status: string | null };

export function parseLocalHistory(json: string): HistoryMatch[] {
  const rows = JSON.parse(json) as AppHistoryRecord[];
  return rows.map((r) => ({ group_name: r.groupName, status: r.status }));
}

const DEFAULT_HISTORY_PATH = join(
  homedir(),
  "Library",
  "Application Support",
  "Overture",
  "overture-history.json",
);

export function loadLocalHistory(path = DEFAULT_HISTORY_PATH): HistoryMatch[] {
  let json: string;
  try {
    json = readFileSync(path, "utf8");
  } catch {
    return [];
  }
  return parseLocalHistory(json);
}
