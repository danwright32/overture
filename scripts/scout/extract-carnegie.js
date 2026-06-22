// Carnegie Hall calendar extractor. Runs IN the page (via Claude Code's headless
// browser / Playwright browser_evaluate) against https://www.carnegiehall.org/Calendar.
// Carnegie's calendar is JavaScript-rendered and bot-protected, so this must run in
// a real browser context, not a plain fetch. Returns structured events with the
// presenter line (which drives the self-produced vs agency-routed classification),
// venue, date, and source URL. Proven against the live site on 2026-06-22.
//
// Usage (inside the scout's browser step):
//   1. navigate to https://www.carnegiehall.org/Calendar
//   2. evaluate this function
//   3. hand `events` to the classification step, then the TS foundation
//      (matchRelationship -> decideProspect) to produce the results file.

() => {
  const anchors = Array.from(document.querySelectorAll('a[href*="/calendar/"]'));
  const seen = new Set();
  const events = [];
  for (const a of anchors) {
    const href = a.getAttribute("href") || "";
    const m = href.match(/\/calendar\/(\d{4})\/(\d{2})\/(\d{2})\//);
    if (!m) continue;
    const title = (a.textContent || "").trim().replace(/\s+/g, " ");
    if (!title || title.length < 3) continue;
    const key = href.split("?")[0];
    if (seen.has(key)) continue;
    seen.add(key);
    // Climb to the surrounding card to capture presenter + venue context text.
    let ctx = a;
    for (let i = 0; i < 4 && ctx.parentElement; i++) ctx = ctx.parentElement;
    const context = (ctx.textContent || "").replace(/\s+/g, " ").trim().slice(0, 300);
    const presenterMatch = context.match(/Presented by ([^]+?)(?= [A-Z]|$)/);
    events.push({
      date: `${m[1]}-${m[2]}-${m[3]}`,
      title,
      sourceUrl: key.startsWith("http") ? key : `https://www.carnegiehall.org${key}`,
      presenter: presenterMatch ? presenterMatch[1].trim() : null,
      context,
    });
  }
  return events;
};
