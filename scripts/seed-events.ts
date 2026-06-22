// Real seed events for dashboard development: performances pulled from Carnegie's
// live upcoming-events calendar (carnegie-calendar.md), classified the way the
// event scout's Claude step will classify them at runtime. This stands in for the
// not-yet-built live scout so the foundation (matcher + ranker + assembly) can run
// end to end against real data. Replace/extend once the live event scout lands.

import type { DiscoveredEvent, Classification } from "../src/lib/assembleProspect";

export type SeedEvent = { event: DiscoveredEvent; classification: Classification };

export const SEED_EVENTS: SeedEvent[] = [
  {
    event: {
      group_name: "Boston & New York International Music Competition Winners' Recital",
      discipline: "music",
      venue: "Weill Recital Hall",
      performance_date: "2026-06-22",
      source_listing_url:
        "https://www.carnegiehall.org/calendar/2026/06/22/boston--new-york-international-music-competition-winners-recital-0700pm",
      website_url: null,
    },
    classification: {
      reachable: true,
      production: "agency",
      profile: "weak",
      coverage: "likely_uncovered",
      fit_reason:
        "Competition-winners Weill rental, exactly the dead zone Dan avoids: easy to find, almost never converts.",
    },
  },
  {
    event: {
      group_name: "National Youth Chorus and National Masterwork Chorus",
      discipline: "choral",
      venue: "Stern Auditorium / Perelman Stage",
      performance_date: "2026-06-22",
      source_listing_url:
        "https://www.carnegiehall.org/calendar/2026/06/22/national-youth-chorus-and-national-masterwork-chorus-0800pm",
      website_url: null,
    },
    classification: {
      reachable: true,
      production: "agency",
      profile: "strong",
      coverage: "unknown",
      fit_reason:
        "Youth choir is a strong fit, but it is agency routed (National Concerts) on the big Stern stage, so reach the choir directly.",
    },
  },
  {
    event: {
      group_name: "Orchestra of St. Luke's",
      discipline: "music",
      venue: "Zankel Hall",
      performance_date: "2026-06-23",
      source_listing_url:
        "https://www.carnegiehall.org/calendar/2026/06/23/orchestra-of-st-lukes-0700pm",
      website_url: null,
    },
    classification: {
      reachable: true,
      production: "self",
      profile: "neutral",
      coverage: "likely_covered",
      fit_reason:
        "Established self-produced orchestra, but a known NYC ensemble that likely has its own photographer; baseline music, not a priority.",
    },
  },
  {
    event: {
      group_name: "New York Rising Stars Concert",
      discipline: "music",
      venue: "Weill Recital Hall",
      performance_date: "2026-06-23",
      source_listing_url:
        "https://www.carnegiehall.org/calendar/2026/06/23/new-york-rising-stars-concert-0730pm",
      website_url: null,
    },
    classification: {
      reachable: true,
      production: "agency",
      profile: "weak",
      coverage: "likely_uncovered",
      fit_reason:
        "Rising-stars showcase rental at Weill, the agency-managed soloist pattern Dan avoids despite being uncovered.",
    },
  },
  {
    event: {
      group_name: "New York Symphonic Invitational",
      discipline: "music",
      venue: "Stern Auditorium / Perelman Stage",
      performance_date: "2026-06-23",
      source_listing_url:
        "https://www.carnegiehall.org/calendar/2026/06/23/new-york-symphonic-invitational-0730pm",
      website_url: null,
    },
    classification: {
      reachable: true,
      production: "agency",
      profile: "neutral",
      coverage: "unknown",
      fit_reason:
        "Tour-operator-assembled invitational on the big stage; agency routed, so not an easy direct booking.",
    },
  },
  {
    event: {
      group_name: "Indianapolis Children's Choir",
      discipline: "choral",
      venue: "Stern Auditorium / Perelman Stage",
      performance_date: "2026-06-24",
      source_listing_url:
        "https://www.carnegiehall.org/calendar/2026/06/24/indianapolis-childrens-choir-0800pm",
      website_url: null,
    },
    classification: {
      reachable: true,
      production: "self",
      profile: "strong",
      coverage: "likely_uncovered",
      fit_reason:
        "Self-produced children's choir, a strong-fit youth ensemble likely without its own NYC photographer; worth reaching directly.",
    },
  },
  {
    event: {
      group_name: "Boston & New York International Music Competition Winners' Recital",
      discipline: "music",
      venue: "Weill Recital Hall",
      performance_date: "2026-06-24",
      source_listing_url:
        "https://www.carnegiehall.org/calendar/2026/06/24/boston--new-york-international-music-competition-winners-recital-0700pm",
      website_url: null,
    },
    classification: {
      reachable: true,
      production: "agency",
      profile: "weak",
      coverage: "likely_uncovered",
      fit_reason: "Same competition-winners Weill rental, the dead zone Dan avoids.",
    },
  },
  {
    event: {
      group_name: "The Presence of Absence (A Cuban Nocturne)",
      discipline: "theater",
      venue: "Thalia Spanish Theatre",
      performance_date: "2026-06-25",
      source_listing_url:
        "https://www.carnegiehall.org/calendar/2026/06/25/the-presence-of-absence-a-cuban-nocturne-0700pm",
      website_url: null,
    },
    classification: {
      reachable: true,
      production: "self",
      profile: "strong",
      coverage: "likely_uncovered",
      fit_reason:
        "Small self-produced cultural theater piece, which Dan ranks above music and is unlikely to have coverage.",
    },
  },
  {
    event: {
      group_name: "Timeless Melodies: Masterpieces Inspiring Generations",
      discipline: "music",
      venue: "Weill Recital Hall",
      performance_date: "2026-06-25",
      source_listing_url:
        "https://www.carnegiehall.org/calendar/2026/06/25/timeless-melodies-masterpieces-inspiring-generations-0700pm",
      website_url: null,
    },
    classification: {
      reachable: true,
      production: "self",
      profile: "strong",
      coverage: "likely_uncovered",
      fit_reason:
        "Self-produced music-school recital at Weill, a strong-fit small group very likely uncovered; good direct outreach target.",
    },
  },
  {
    event: {
      group_name: "Carnegie Hall Citywide: TONEWALL",
      discipline: "music",
      venue: "Wave Hill",
      performance_date: "2026-06-25",
      source_listing_url:
        "https://www.carnegiehall.org/calendar/2026/06/25/carnegie-hall-citywide-tonewall-0700pm",
      website_url: null,
    },
    classification: {
      reachable: true,
      production: "agency",
      profile: "neutral",
      coverage: "likely_covered",
      fit_reason:
        "Free Citywide concert produced by Carnegie at an off-site park; house-programmed, so likely already has its own coverage.",
    },
  },
];
