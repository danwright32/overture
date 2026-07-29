import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  assertPrepQueueShape,
  assertPrepResultsShape,
  assertPrepProgressShape,
  assertReplyClassifyQueueShape,
  assertReplyClassifyResultsShape,
  assertVoiceFeedbackShape,
  versionFromFilename,
} from "./fixtureShape";

// Shape-drift guard (#509) for the contracts where at least one side is not code with no
// automated test (docs/contracts.md's "CI coverage" section): prep-queue,
// prep-results, prep-progress, reply-classify, voice-feedback. This does not test behavior (the
// non-code side isn't code); it only asserts every fixture actually committed under each
// directory still matches its documented shape, so a format change on the non-code side that the
// fixture was never updated for fails here instead of drifting silently (the #109 class of bug).

const fixtureDir = (dir: string) => fileURLToPath(new URL(`../../fixtures/${dir}/`, import.meta.url));

function readJson(dir: string, filename: string): unknown {
  return JSON.parse(readFileSync(`${fixtureDir(dir)}${filename}`, "utf8"));
}

function jsonFilenames(dir: string): string[] {
  return readdirSync(fixtureDir(dir)).filter((f) => f.endsWith(".json"));
}

describe("prep-queue fixture shapes", () => {
  const files = jsonFilenames("prep-queue");

  it("covers exactly the known prep-queue files", () => {
    expect(files.sort()).toEqual(["v1.json", "v2.json", "v3.json", "v4.json", "v5.json", "v6.json"]);
  });

  for (const file of files) {
    it(`${file} matches the prep-queue shape`, () => {
      const version = versionFromFilename(file);
      expect(() => assertPrepQueueShape(readJson("prep-queue", file), file, version)).not.toThrow();
    });
  }

  // #1122: the run fields are v4 additions, so the guard must reject them appearing in an older
  // fixture, the same way the prep-results guard rejects a too-new field below.
  // #5: experimentArmInstruction is a v5 addition, so the guard must reject it on an older version.
  it("rejects a v5 experiment field appearing in a v4 fixture", () => {
    const mutated = readJson("prep-queue", "v4.json") as { items: Array<Record<string, unknown>> };
    mutated.items[0].experimentArmInstruction = "credential-first";
    expect(() => assertPrepQueueShape(mutated, "v4.json", 4)).toThrow(/experimentArmInstruction.*before version 5/);
  });

  // #5: the archetype must be one of the four known tokens, not free text.
  it("rejects an unknown experiment archetype token in a v5 fixture", () => {
    const mutated = readJson("prep-queue", "v5.json") as { items: Array<Record<string, unknown>> };
    mutated.items[0].experimentArmInstruction = "made-up-shape";
    expect(() => assertPrepQueueShape(mutated, "v5.json", 5)).toThrow(/experimentArmInstruction/);
  });

  // #1597: alsoAnswersFor is a v6 addition. A runner reading an older queue does not know the rule, so
  // silently accepting the field there would mean every covered show came back unanswered.
  it("rejects a v6 grouping field appearing in a v5 fixture", () => {
    const mutated = readJson("prep-queue", "v5.json") as { items: Array<Record<string, unknown>> };
    mutated.items[0].alsoAnswersFor = ["some-other-key"];
    expect(() => assertPrepQueueShape(mutated, "v5.json", 5)).toThrow(/alsoAnswersFor.*before version 6/);
  });

  it("rejects a grouping list holding anything but strings", () => {
    const mutated = readJson("prep-queue", "v6.json") as { items: Array<Record<string, unknown>> };
    mutated.items[0].alsoAnswersFor = ["fine", 7];
    expect(() => assertPrepQueueShape(mutated, "v6.json", 6)).toThrow(/alsoAnswersFor\[1\]/);
  });

  // An item listing itself would make the run emit two result entries under one key, which the importer
  // would apply twice. The app never builds one, so a fixture holding one is a real defect.
  it("rejects an item that lists its own key among the shows it answers for", () => {
    const mutated = readJson("prep-queue", "v6.json") as {
      items: Array<Record<string, unknown>>;
    };
    mutated.items[0].alsoAnswersFor = [mutated.items[0].naturalKey as string];
    expect(() => assertPrepQueueShape(mutated, "v6.json", 6)).toThrow(/must not repeat/);
  });

  it("rejects a v4 run field appearing in a v3 fixture", () => {
    const mutated = readJson("prep-queue", "v3.json") as { items: Array<Record<string, unknown>> };
    mutated.items[0].runEndDate = "2026-03-14";
    expect(() => assertPrepQueueShape(mutated, "v3.json", 3)).toThrow(/runEndDate.*before version 4/);
  });
});

describe("prep-results fixture shapes", () => {
  const files = jsonFilenames("prep-results");

  it("covers exactly the known prep-results files", () => {
    expect(files.sort()).toEqual(["v1.json", "v2.json", "v3.json", "v4.json", "v5.json", "v6.json", "v7.json"]);
  });

  for (const file of files) {
    it(`${file} matches the prep-results shape`, () => {
      const version = versionFromFilename(file);
      expect(() => assertPrepResultsShape(readJson("prep-results", file), file, version)).not.toThrow();
    });
  }

  // #1722: the deterministic boundary check the runbook rule needs behind it (LESSONS L27). A rule that
  // lives only in a prompt is a hope, so an entry that gives up on a show without saying why is refused
  // here rather than degrading silently to "No email found" on Dan's card.
  it("rejects a v7 entry that has no contacts and does not say why", () => {
    const mutated = readJson("prep-results", "v7.json") as { results: Array<Record<string, unknown>> };
    delete mutated.results[1].emptyReason;
    expect(() => assertPrepResultsShape(mutated, "v7.json", 7)).toThrow(/must carry an emptyReason/);
  });

  it("rejects a v7 entry whose reason is not one the app can explain", () => {
    const mutated = readJson("prep-results", "v7.json") as { results: Array<Record<string, unknown>> };
    mutated.results[1].emptyReason = "invented_by_a_newer_run";
    expect(() => assertPrepResultsShape(mutated, "v7.json", 7)).toThrow(/emptyReason must be one of/);
  });

  it("rejects a v6 file that already carries the v7 emptyReason field", () => {
    const mutated = readJson("prep-results", "v6.json") as { results: Array<Record<string, unknown>> };
    mutated.results[0].emptyReason = "only_venue_contact";
    expect(() => assertPrepResultsShape(mutated, "v6.json", 6)).toThrow(/must not be present before version 7/);
  });

  it("rejects a v1 file that already carries the v2 contacts[] replacement field", () => {
    const mutated = readJson("prep-results", "v1.json") as { results: Array<Record<string, unknown>> };
    mutated.results[0].contacts = [];
    expect(() => assertPrepResultsShape(mutated, "v1.json", 1)).toThrow(/contacts.*must not be present/);
  });

  it("rejects a v2 file that regressed to the replaced singular contact field", () => {
    const mutated = readJson("prep-results", "v2.json") as { results: Array<Record<string, unknown>> };
    mutated.results[0].contact = { method: "generic_inbox", confidence: "low" };
    expect(() => assertPrepResultsShape(mutated, "v2.json", 2)).toThrow(/contact.*replaced by contacts/);
  });

  it("rejects a v3 file whose contact already carries the v4 overrideBody field", () => {
    const mutated = readJson("prep-results", "v3.json") as {
      results: Array<{ contacts?: Array<Record<string, unknown>> }>;
    };
    mutated.results[0].contacts![0].overrideBody = "I saw you...";
    expect(() => assertPrepResultsShape(mutated, "v3.json", 3)).toThrow(/overrideBody.*before version 4/);
  });

  it("rejects a v4 file whose result already carries the v5 alreadyCoveredNote field", () => {
    const mutated = readJson("prep-results", "v4.json") as { results: Array<Record<string, unknown>> };
    mutated.results[0].alreadyCoveredNote = "Lists its own photographer.";
    expect(() => assertPrepResultsShape(mutated, "v4.json", 4)).toThrow(/alreadyCoveredNote.*before version 5/);
  });

  it("rejects a v5 file whose contact already carries the v6 sourceUrl field", () => {
    const mutated = readJson("prep-results", "v5.json") as {
      results: Array<{ contacts?: Array<Record<string, unknown>> }>;
    };
    mutated.results[0].contacts![0].sourceUrl = "https://example.com/about/staff";
    expect(() => assertPrepResultsShape(mutated, "v5.json", 5)).toThrow(/sourceUrl.*before version 6/);
  });
});

describe("prep-progress fixture shapes", () => {
  const files = jsonFilenames("prep-progress");

  it("covers exactly the known prep-progress files", () => {
    expect(files.sort()).toEqual(["v1.json"]);
  });

  for (const file of files) {
    it(`${file} matches the prep-progress shape`, () => {
      const version = versionFromFilename(file);
      expect(() => assertPrepProgressShape(readJson("prep-progress", file), file, version)).not.toThrow();
    });
  }

  it("rejects completed exceeding total (proves the check actually catches drift)", () => {
    const mutated = readJson("prep-progress", "v1.json") as Record<string, unknown>;
    mutated.completed = (mutated.total as number) + 1;
    expect(() => assertPrepProgressShape(mutated, "v1.json", 1)).toThrow(/completed.*must not exceed total/);
  });

  it("rejects a negative total", () => {
    const mutated = readJson("prep-progress", "v1.json") as Record<string, unknown>;
    mutated.total = -1;
    expect(() => assertPrepProgressShape(mutated, "v1.json", 1)).toThrow(/total must be a non-negative integer/);
  });
});

describe("reply-classify fixture shapes", () => {
  const files = jsonFilenames("reply-classify");

  it("covers exactly the known reply-classify files", () => {
    expect(files.sort()).toEqual([
      "queue-v2.json",
      "queue-v3.json",
      "queue.json",
      "results-v2.json",
      "results-v3.json",
      "results.json",
    ]);
  });

  for (const file of files.filter((f) => f.startsWith("queue"))) {
    it(`${file} matches the reply-classify queue shape`, () => {
      const version = versionFromFilename(file);
      expect(() => assertReplyClassifyQueueShape(readJson("reply-classify", file), file, version)).not.toThrow();
    });
  }

  for (const file of files.filter((f) => f.startsWith("results"))) {
    it(`${file} matches the reply-classify results shape`, () => {
      const version = versionFromFilename(file);
      expect(() => assertReplyClassifyResultsShape(readJson("reply-classify", file), file, version)).not.toThrow();
    });
  }

  it("rejects a results file whose intent is not one of the documented ReplyIntent values", () => {
    const mutated = readJson("reply-classify", "results.json") as { results: Array<Record<string, unknown>> };
    mutated.results[0].intent = "maybe_interested";
    expect(() => assertReplyClassifyResultsShape(mutated, "results.json", 1)).toThrow(/intent must be one of/);
  });
});

describe("voice-feedback fixture shapes", () => {
  const files = jsonFilenames("voice-feedback");

  it("covers exactly the known voice-feedback files", () => {
    expect(files.sort()).toEqual(["v1.json", "v2.json", "v3.json"]);
  });

  for (const file of files) {
    it(`${file} matches the voice-feedback shape`, () => {
      const version = versionFromFilename(file);
      expect(() => assertVoiceFeedbackShape(readJson("voice-feedback", file), file, version)).not.toThrow();
    });
  }

  it("rejects a pair missing a required field (proves the check actually catches drift)", () => {
    const mutated = readJson("voice-feedback", "v1.json") as { pairs: Array<Record<string, unknown>> };
    delete mutated.pairs[0].sentBody;
    expect(() => assertVoiceFeedbackShape(mutated, "v1.json", 1)).toThrow(/sentBody must be a non-empty string/);
  });

  it("rejects a kind value outside the documented reply/absent set", () => {
    const mutated = readJson("voice-feedback", "v3.json") as { pairs: Array<Record<string, unknown>> };
    mutated.pairs[0].kind = "forwarded";
    expect(() => assertVoiceFeedbackShape(mutated, "v3.json", 3)).toThrow(/kind must be one of/);
  });

  it("rejects a version field that does not match what the filename encodes", () => {
    const mutated = readJson("voice-feedback", "v2.json") as Record<string, unknown>;
    mutated.version = 1;
    expect(() => assertVoiceFeedbackShape(mutated, "v2.json", 2)).toThrow(/does not match filename version/);
  });
});
