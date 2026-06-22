// Rule-based classifier for the event scout. Turns a raw extracted calendar event
// into the ranker's classification inputs from simple signals (presenter, venue,
// title keywords). Free, instant, deterministic. Genuinely ambiguous events are
// marked `confidence: "uncertain"` so an optional AI refine pass can revisit only
// those, never the whole calendar. See docs/scout-runbook.md and PLAN.md section 4.

import type { Candidate } from "./ranker";

export type ExtractedEvent = {
  title: string;
  presenter: string | null;
  venue: string | null;
  performanceDate: string | null;
  sourceUrl: string | null;
};

export type EventClassification = {
  discipline: Candidate["discipline"];
  reachable: boolean;
  production: Candidate["production"];
  profile: Candidate["profile"];
  coverage: Candidate["coverage"];
  fit_reason: string;
  confidence: "confident" | "uncertain";
};

// Presenters/titles that signal an agency- or tour-operator-routed showcase rental:
// the calendar's biggest dead zone for cold outreach.
const AGENCY_SIGNAL =
  /competition|winners|rising stars|invitational|young artists?|debut|showcase|celebrations international|concerts international|distinguished concerts|mid.?america|national concerts|jam generation|tour|gala of/i;

// Producing-organization words: a presenter that names one of these is a real group
// putting on its own show, not a rental middleman.
const PRODUCER_SIGNAL =
  /choir|chorus|chorale|choral|orchestra|philharmonic|ensemble|consort|school|academy|conservatory|university|college|institute|theatre|theater|company|opera|ballet|dance|society|center|centre|foundation|church|temple|youth|community|collective|quartet|quintet|band/i;

// Strong-fit profile words (Dan's high-converting niche).
const STRONG_PROFILE =
  /choir|chorus|chorale|choral|school|academy|conservatory|youth|community|children|ensemble|opera|ballet|dance|theatre|theater|cultural|university|college|church|temple/i;

function detectDiscipline(text: string): Candidate["discipline"] {
  if (/\b(dance|ballet|balletto|tap|choreograph|nutcracker)\b/i.test(text)) return "dance";
  if (/\b(opera|operetta)\b/i.test(text)) return "opera";
  // "play" / "musical" are too common in names (e.g. "Play It Forward School of
  // Music") to be reliable theater signals; rely on unambiguous words.
  if (/\b(theatre|theater|drama|cabaret|playhouse)\b/i.test(text)) return "theater";
  if (/\b(choir|chorus|chorale|choral|voices|singers|cantata|vocal)\b/i.test(text)) return "choral";
  if (/\b(band|wind ensemble|brass|jazz band|marching)\b/i.test(text)) return "band";
  if (/\b(comedy|comedian|stand.?up|improv)\b/i.test(text)) return "comedy";
  return "music";
}

export function classifyEvent(event: ExtractedEvent): EventClassification {
  const presenter = event.presenter ?? "";
  const venue = event.venue ?? "";
  const haystack = `${event.title} ${presenter}`;
  const discipline = detectDiscipline(haystack);

  const isAgency = AGENCY_SIGNAL.test(haystack);
  const isProducer = !!presenter && PRODUCER_SIGNAL.test(presenter) && !isAgency;

  let production: Candidate["production"];
  if (isAgency) production = "agency";
  else if (isProducer) production = "self";
  else production = "unknown";

  let profile: Candidate["profile"];
  if (isAgency) profile = "weak";
  else if (isProducer && STRONG_PROFILE.test(haystack)) profile = "strong";
  else profile = "neutral";

  // Weill recitals are small and almost always uncovered. A self-produced strong
  // group is likely uncovered too. Everything else the rules leave at unknown.
  const atWeill = /weill/i.test(venue);
  let coverage: Candidate["coverage"];
  if (atWeill || (production === "self" && profile === "strong")) {
    coverage = "likely_uncovered";
  } else {
    coverage = "unknown";
  }

  // For v1 every surfaced Carnegie/NYC venue is reachable; the travel gate (PLAN
  // section 8) refines this later.
  const reachable = true;

  // Ambiguous when the rules cannot pin production, or land on a flat neutral
  // profile with no clear signal: exactly the cases worth an AI second look.
  const confidence: EventClassification["confidence"] =
    production === "unknown" || (production === "self" && profile === "neutral")
      ? "uncertain"
      : "confident";

  return {
    discipline,
    reachable,
    production,
    profile,
    coverage,
    fit_reason: buildReason({ production, profile, coverage, discipline, venue }),
    confidence,
  };
}

function buildReason(p: {
  production: Candidate["production"];
  profile: Candidate["profile"];
  coverage: Candidate["coverage"];
  discipline: Candidate["discipline"];
  venue: string;
}): string {
  if (p.production === "agency" && p.profile === "weak") {
    return "Agency-routed showcase rental, the dead zone that rarely converts.";
  }
  if (p.production === "self" && p.profile === "strong") {
    const where = p.coverage === "likely_uncovered" ? ", likely without its own photographer" : "";
    return `Self-produced ${p.discipline} group, a strong-fit target${where}.`;
  }
  if (p.production === "self") {
    return `Self-produced ${p.discipline}; worth a look once the fit is confirmed.`;
  }
  return "Unclear producer; needs a closer look before pitching.";
}
