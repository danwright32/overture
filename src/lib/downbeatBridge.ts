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

export type DownbeatExport = {
  clients: DownbeatClient[];
  venues: DownbeatVenue[];
};

const SUPPORTED_VERSION = 1;

export function parseDownbeatExport(json: string): DownbeatExport {
  const data = JSON.parse(json) as {
    version?: number;
    clients?: DownbeatClient[];
    venues?: DownbeatVenue[];
  };
  if (data.version !== SUPPORTED_VERSION) {
    throw new Error(
      `Unsupported Downbeat export version: ${String(data.version)}`,
    );
  }
  return { clients: data.clients ?? [], venues: data.venues ?? [] };
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
