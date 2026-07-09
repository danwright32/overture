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
    expect(files.sort()).toEqual(["v1.json", "v2.json"]);
  });

  for (const file of files) {
    it(`${file} matches the prep-queue shape`, () => {
      const version = versionFromFilename(file);
      expect(() => assertPrepQueueShape(readJson("prep-queue", file), file, version)).not.toThrow();
    });
  }
});

describe("prep-results fixture shapes", () => {
  const files = jsonFilenames("prep-results");

  it("covers exactly the known prep-results files", () => {
    expect(files.sort()).toEqual(["v1.json", "v2.json", "v3.json", "v4.json", "v5.json"]);
  });

  for (const file of files) {
    it(`${file} matches the prep-results shape`, () => {
      const version = versionFromFilename(file);
      expect(() => assertPrepResultsShape(readJson("prep-results", file), file, version)).not.toThrow();
    });
  }

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
