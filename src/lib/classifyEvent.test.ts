import { describe, it, expect } from "vitest";
import { classifyEvent, type ExtractedEvent } from "./classifyEvent";

function ev(over: Partial<ExtractedEvent> = {}): ExtractedEvent {
  return {
    title: "Some Performance",
    presenter: null,
    venue: "Weill Recital Hall",
    performanceDate: "2026-06-25",
    sourceUrl: null,
    ...over,
  };
}

describe("classifyEvent: clear dead-zone cases", () => {
  it("flags a competition-winners Weill rental as agency / weak / uncovered, confidently", () => {
    const c = classifyEvent(
      ev({
        title: "Boston & New York International Music Competition Winners' Recital",
        presenter: "Jam Generation",
        venue: "Weill Recital Hall",
      }),
    );
    expect(c.production).toBe("agency");
    expect(c.profile).toBe("weak");
    expect(c.coverage).toBe("likely_uncovered");
    expect(c.discipline).toBe("music");
    expect(c.confidence).toBe("confident");
  });

  it("flags a rising-stars showcase as agency / weak", () => {
    const c = classifyEvent(
      ev({ title: "New York Rising Stars Concert", presenter: "New York Young Arts Foundation" }),
    );
    expect(c.production).toBe("agency");
    expect(c.profile).toBe("weak");
    expect(c.confidence).toBe("confident");
  });
});

describe("classifyEvent: clear strong-fit cases", () => {
  it("classifies a self-produced children's choir as self / strong / choral", () => {
    const c = classifyEvent(
      ev({
        title: "Indianapolis Children's Choir",
        presenter: "Indianapolis Children's Choir",
        venue: "Stern Auditorium / Perelman Stage",
      }),
    );
    expect(c.production).toBe("self");
    expect(c.profile).toBe("strong");
    expect(c.discipline).toBe("choral");
    expect(c.coverage).toBe("likely_uncovered");
    expect(c.confidence).toBe("confident");
  });

  it("classifies a self-produced cultural theater piece as self / theater", () => {
    const c = classifyEvent(
      ev({
        title: "The Presence of Absence (A Cuban Nocturne)",
        presenter: "Cuban Cultural Center of New York and Thalia Spanish Theatre",
        venue: "Thalia Spanish Theatre",
      }),
    );
    expect(c.production).toBe("self");
    expect(c.discipline).toBe("theater");
    expect(c.profile).toBe("strong");
  });

  it("classifies a self-produced music-school recital as self / strong", () => {
    const c = classifyEvent(
      ev({
        title: "Timeless Melodies: Masterpieces Inspiring Generations",
        presenter: "Play It Forward School of Music",
        venue: "Weill Recital Hall",
      }),
    );
    expect(c.production).toBe("self");
    expect(c.profile).toBe("strong");
    expect(c.coverage).toBe("likely_uncovered");
  });
});

describe("classifyEvent: discipline detection", () => {
  it("detects dance, opera, choral, band from title keywords", () => {
    expect(classifyEvent(ev({ title: "Spring Ballet Gala" })).discipline).toBe("dance");
    expect(classifyEvent(ev({ title: "La Bohème: Opera in Concert" })).discipline).toBe("opera");
    expect(classifyEvent(ev({ title: "Brooklyn Youth Chorus" })).discipline).toBe("choral");
    expect(classifyEvent(ev({ title: "Wind Ensemble Showcase" })).discipline).toBe("band");
  });

  it("falls back to music when no discipline keyword is present", () => {
    expect(classifyEvent(ev({ title: "An Evening of Chopin" })).discipline).toBe("music");
  });

  it("does not misread common words like 'Play' in a name as theater", () => {
    const c = classifyEvent(
      ev({ title: "Timeless Melodies", presenter: "Play It Forward School of Music" }),
    );
    expect(c.discipline).toBe("music");
  });
});

describe("classifyEvent: ambiguity is flagged, not guessed", () => {
  it("marks an established self-presented orchestra as uncertain for the AI to refine", () => {
    const c = classifyEvent(
      ev({
        title: "Orchestra of St. Luke's",
        presenter: "Orchestra of St. Luke's",
        venue: "Zankel Hall",
      }),
    );
    // Rules can tell it is self-produced, but cannot judge whether an established
    // orchestra is already covered; that nuance is left for the AI refine pass.
    expect(c.production).toBe("self");
    expect(c.confidence).toBe("uncertain");
  });

  it("marks an unknown presenter as uncertain", () => {
    const c = classifyEvent(ev({ title: "Gala Concert", presenter: null }));
    expect(c.confidence).toBe("uncertain");
  });

  it("always returns a usable fit_reason and reachable flag", () => {
    const c = classifyEvent(ev());
    expect(c.fit_reason.length).toBeGreaterThan(0);
    expect(typeof c.reachable).toBe("boolean");
  });
});
