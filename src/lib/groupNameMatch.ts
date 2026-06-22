// Name matching for repeat-client detection. Calendar group names are messy
// (presenter + program title, often multi-line); these helpers normalize them
// and decide confident vs merely-possible matches. Precision is prioritized:
// only confident matches drive scoring, possibles are flagged for review.

export function normalizeGroupName(name: string): string {
  const firstLine = name.split("\n")[0] ?? "";
  return firstLine
    .toLowerCase()
    .replace(/^\s*presented by\s+/i, "")
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function tokens(name: string): string[] {
  return normalizeGroupName(name).split(" ").filter(Boolean);
}

export function isConfidentMatch(a: string, b: string): boolean {
  const na = normalizeGroupName(a);
  const nb = normalizeGroupName(b);
  if (na === "" || nb === "") return false;
  if (na === nb) return true;
  const shorter = na.length <= nb.length ? na : nb;
  const longer = shorter === na ? nb : na;
  if (longer.includes(shorter) && shorter.split(" ").length >= 2) return true;
  return false;
}

export function isPossibleMatch(a: string, b: string): boolean {
  if (isConfidentMatch(a, b)) return false;
  const ta = new Set(tokens(a));
  const tb = new Set(tokens(b));
  if (ta.size === 0 || tb.size === 0) return false;
  let shared = 0;
  for (const t of ta) if (tb.has(t)) shared += 1;
  const union = new Set([...ta, ...tb]).size;
  return shared / union >= 0.5;
}
