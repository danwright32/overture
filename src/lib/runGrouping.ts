// Collapse a multi-night run (same group + venue, performances <=3 days apart) into the
// opening night's row, tagged with the run's closing date, all member source URLs, and a
// flag when the same group+venue has more than one run/date in the batch. Mirrors
// RunGrouping.swift. See docs/superpowers/specs/2026-06-25-multi-night-run-collapse-design.md.

export type RunRow = {
  groupName: string;
  venue: string | null;
  performanceDate: string | null;
  sourceListingUrl: string | null;
};

export type RunFields = {
  runEndDate: string | null;
  partOfRelatedRun: boolean;
  runSourceURLs: string[];
};

const GAP_DAYS = 3;

function canon(s: string | null): string {
  return (s ?? "").toLowerCase().replace(/\s+/g, " ").trim();
}

function dayNumber(date: string): number {
  const [y, m, d] = date.split("-").map(Number);
  return Math.floor(Date.UTC(y, m - 1, d) / 86_400_000);
}

export function groupIntoRuns<T extends RunRow>(rows: T[]): (T & RunFields)[] {
  const undated = rows.filter((r) => !r.performanceDate);
  const dated = rows.filter((r) => r.performanceDate);

  const byGroup = new Map<string, T[]>();
  for (const r of dated) {
    const key = `${canon(r.groupName)}|${canon(r.venue)}`;
    (byGroup.get(key) ?? byGroup.set(key, []).get(key)!).push(r);
  }

  const out: (T & RunFields)[] = [];
  for (const group of byGroup.values()) {
    group.sort((a, b) => (a.performanceDate! < b.performanceDate! ? -1 : 1));
    const runs: T[][] = [];
    for (const r of group) {
      const last = runs[runs.length - 1];
      const prev = last?.[last.length - 1];
      if (prev && dayNumber(r.performanceDate!) - dayNumber(prev.performanceDate!) <= GAP_DAYS) {
        last.push(r);
      } else {
        runs.push([r]);
      }
    }
    const related = runs.length > 1;
    for (const run of runs) {
      const open = run[0];
      const close = run[run.length - 1];
      out.push({
        ...open,
        runEndDate: run.length > 1 ? close.performanceDate : null,
        partOfRelatedRun: related,
        runSourceURLs: run.map((r) => r.sourceListingUrl).filter((u): u is string => !!u),
      });
    }
  }

  for (const r of undated) {
    out.push({ ...r, runEndDate: null, partOfRelatedRun: false, runSourceURLs: r.sourceListingUrl ? [r.sourceListingUrl] : [] });
  }
  return out;
}
