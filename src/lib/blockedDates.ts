// True when a performance falls on a date Dan dismissed as "day does not work,"
// so the scout never resurfaces it.

export function isBlockedDate(
  date: string | null,
  blocked: Set<string>,
): boolean {
  if (!date) return false;
  return blocked.has(date);
}
