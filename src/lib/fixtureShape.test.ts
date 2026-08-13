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

// #2340: which version's rules a fixture is checked against comes from its NAME, so a name that
// carries no version has no answer, and the old default of 1 turned that into a confident wrong one.
// Hit for real on 2026-08-08 (#1678's run-metadata fixtures, checked as version 1 while their own
// `version` field said 8) and caught only because the file argued back.
describe("the version a fixture filename encodes (#2340)", () => {
  it("reads the version off the suffix", () => {
    expect(versionFromFilename("v1.json")).toBe(1);
    expect(versionFromFilename("v12.json")).toBe(12);
    expect(versionFromFilename("queue-v3.json")).toBe(3);
    expect(versionFromFilename("run-metadata-complete-v8.json")).toBe(8);
  });

  it("refuses a name with no version instead of calling it version 1", () => {
    expect(() => versionFromFilename("run-metadata-complete.json"))
      .toThrow(/carries no version/);
    expect(() => versionFromFilename("queue.json")).toThrow(/carries no version/);
  });

  // The refusal has to name the file, because it fires from a loop over a whole directory and a
  // message that does not say which one leaves the reader to find it by hand.
  it("names the file it refused", () => {
    expect(() => versionFromFilename("uncertain.json")).toThrow(/uncertain\.json/);
  });

  // And the reason the refusal is safe to ship: every fixture the suite actually reads carries one.
  it("every fixture in every checked directory carries a version in its name", () => {
    for (const dir of ["prep-queue", "prep-results", "prep-progress", "reply-classify",
                       "reply-classify-progress", "voice-feedback"]) {
      for (const file of jsonFilenames(dir)) {
        expect(() => versionFromFilename(file), `${dir}/${file}`).not.toThrow();
      }
    }
  });
});

describe("prep-queue fixture shapes", () => {
  const files = jsonFilenames("prep-queue");

  it("covers exactly the known prep-queue files", () => {
    expect(files.sort()).toEqual([
      // Lexicographic, because the assertion compares against files.sort(): "v10" sorts next to "v1".
      "v1.json", "v10.json", "v11.json", "v12.json", "v2.json", "v3.json", "v4.json", "v5.json",
      "v6.json", "v7.json", "v8.json", "v9.json",
    ]);
  });

  for (const file of files) {
    it(`${file} matches the prep-queue shape`, () => {
      const version = versionFromFilename(file);
      expect(() => assertPrepQueueShape(readJson("prep-queue", file), file, version)).not.toThrow();
    });
  }

  // #2259: the company a listing credits is a v11 addition, so it must be rejected on an older fixture
  // that a runner predating the rule would read.
  it("rejects a v11 listing organisation appearing in a v10 fixture", () => {
    const mutated = readJson("prep-queue", "v10.json") as { items: Array<Record<string, unknown>> };
    mutated.items[0].organisationNamedOnListing = "Fenwick Productions";
    expect(() => assertPrepQueueShape(mutated, "v10.json", 10))
      .toThrow(/organisationNamedOnListing.*before version 11/);
  });

  // Empty is not a company. Written as "" it would read as an answer the app never found, which is the
  // exact confusion this field exists to end.
  it("rejects an empty listing organisation in a v11 fixture", () => {
    const mutated = readJson("prep-queue", "v11.json") as { items: Array<Record<string, unknown>> };
    mutated.items[1].organisationNamedOnListing = "  ";
    expect(() => assertPrepQueueShape(mutated, "v11.json", 11)).toThrow(/must be absent rather than empty/);
  });

  // The app can only have read a credit off a page it read. A name with no listing beside it came from
  // somewhere else, and the runbook would treat it as read from the page.
  it("rejects a listing organisation on an item carrying no listing", () => {
    const mutated = readJson("prep-queue", "v11.json") as { items: Array<Record<string, unknown>> };
    delete mutated.items[1].showListing;
    expect(() => assertPrepQueueShape(mutated, "v11.json", 11)).toThrow(/requires a showListing/);
  });

  // #1122: the run fields are v4 additions, so the guard must reject them appearing in an older
  // fixture, the same way the prep-results guard rejects a too-new field below.
  // #5: experimentArmInstruction is a v5 addition, so the guard must reject it on an older version.
  it("rejects a v5 experiment field appearing in a v4 fixture", () => {
    const mutated = readJson("prep-queue", "v4.json") as { items: Array<Record<string, unknown>> };
    mutated.items[0].experimentArmInstruction = "credential-first";
    expect(() => assertPrepQueueShape(mutated, "v4.json", 4)).toThrow(/experimentArmInstruction.*before version 5/);
  });

  // #5: the archetype must be one of the known tokens, not free text.
  it("rejects an unknown experiment archetype token in a v5 fixture", () => {
    const mutated = readJson("prep-queue", "v5.json") as { items: Array<Record<string, unknown>> };
    mutated.items[0].experimentArmInstruction = "made-up-shape";
    expect(() => assertPrepQueueShape(mutated, "v5.json", 5)).toThrow(/experimentArmInstruction/);
  });

  // 2026-07-31: credential-first and observation-first are retired, and the two directions differ.
  // INBOUND, an arm stamped on a prospect before the retirement is real history that must still decode:
  // refusing it here would break a queue built from the live store, which is why the assignable list
  // deliberately keeps all four tokens.
  it("still accepts a retired archetype as an assigned arm, since a prospect may carry one", () => {
    const mutated = readJson("prep-queue", "v5.json") as { items: Array<Record<string, unknown>> };
    for (const token of ["credential-first", "observation-first"]) {
      mutated.items[0].experimentArmInstruction = token;
      expect(() => assertPrepQueueShape(mutated, "v5.json", 5)).not.toThrow();
    }
  });

  // OUTBOUND is deliberately NOT judged here. The frozen results fixtures carry `rate_stated`, a token
  // from the retired offer A/B (#612), so this guard's contract (every past results file still decodes)
  // rules out treating `variant` as today's vocabulary. prepEval judges the produced shape instead.
  it("accepts any string variant, since past results files carry retired experiment tokens", () => {
    const mutated = readJson("prep-results", "v5.json") as {
      results: Array<{ draft?: Record<string, unknown> }>;
    };
    const withDraft = mutated.results.find((r) => r.draft);
    if (!withDraft?.draft) throw new Error("fixture has no drafted result to mutate");
    withDraft.draft.variant = "rate_stated";
    expect(() => assertPrepResultsShape(mutated, "v5.json", 5)).not.toThrow();
    withDraft.draft.variant = 42;
    expect(() => assertPrepResultsShape(mutated, "v5.json", 5)).toThrow(/variant/);
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

  // #1720: the run-level house list is a v7 addition. A runner reading an older queue has no rule for
  // it, so a stamp on a v1-v6 file must be caught rather than silently ignored by a run that would then
  // go on deciding for itself which organisation is the building.
  it("rejects a v7 house list appearing in a v6 fixture", () => {
    const mutated = readJson("prep-queue", "v6.json") as Record<string, unknown>;
    mutated.houses = [{ key: "abrons arts center", name: "Abrons Arts Center" }];
    expect(() => assertPrepQueueShape(mutated, "v6.json", 6)).toThrow(/houses.*before version 7/);
  });

  // Both halves are load-bearing and they fail differently. Without the folded key the run has nothing
  // to match exactly; without the readable name it cannot recognise a spelling it read on a page. A
  // half-populated entry would quietly weaken the match rather than break it.
  it("rejects a house entry missing its folded key", () => {
    const mutated = readJson("prep-queue", "v7.json") as Record<string, unknown>;
    mutated.houses = [{ name: "Abrons Arts Center" }];
    expect(() => assertPrepQueueShape(mutated, "v7.json", 7)).toThrow(/houses\[0\]\.key/);
  });

  it("rejects a house entry missing its readable name", () => {
    const mutated = readJson("prep-queue", "v7.json") as Record<string, unknown>;
    mutated.houses = [{ key: "abrons arts center" }];
    expect(() => assertPrepQueueShape(mutated, "v7.json", 7)).toThrow(/houses\[0\]\.name/);
  });

  // The key is what an exact lookup compares against, so a key carrying capitals or a leading "the" has
  // been folded by something other than ProducerGate.key and would simply never match.
  it("rejects a house key that has not been folded", () => {
    const mutated = readJson("prep-queue", "v7.json") as Record<string, unknown>;
    mutated.houses = [{ key: "The Abrons Arts Center", name: "Abrons Arts Center" }];
    expect(() => assertPrepQueueShape(mutated, "v7.json", 7)).toThrow(/houses\[0\]\.key/);
  });

  it("rejects a v4 run field appearing in a v3 fixture", () => {
    const mutated = readJson("prep-queue", "v3.json") as { items: Array<Record<string, unknown>> };
    mutated.items[0].runEndDate = "2026-03-14";
    expect(() => assertPrepQueueShape(mutated, "v3.json", 3)).toThrow(/runEndDate.*before version 4/);
  });
});

describe("prep-results fixture shapes", () => {
  const files = jsonFilenames("prep-results");

  // #1678: the two run-metadata files are not a new VERSION of the results shape. They carry the three
  // top-level keys prep-run.sh adds after the workflow has finished (model, runCost, webCalls), on top of
  // v8's results, hence the -v8 suffix: the version in the name is what this suite validates each file
  // against, so a fixture whose name does not carry one would be checked against version 1.
  it("covers exactly the known prep-results files", () => {
    expect(files.sort()).toEqual(["run-metadata-complete-v8.json", "run-metadata-partial-v8.json",
                                  "v1.json", "v2.json", "v3.json", "v4.json", "v5.json", "v6.json",
                                  "v7.json", "v8.json", "v9.json"]);
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

  // #1817: a check that could not work out who to write to says exactly that, so the validator has to
  // accept it. Widening the value list rather than bumping the version is safe in ONE direction only, and
  // the test below is the other half: an unknown value is still refused, so a run cannot invent a reason
  // the app has no sentence for and have it pass as a claim.
  it("accepts a v7 entry saying nobody could be identified to pursue", () => {
    const mutated = readJson("prep-results", "v7.json") as { results: Array<Record<string, unknown>> };
    mutated.results[1].emptyReason = "no_one_identified";
    expect(() => assertPrepResultsShape(mutated, "v7.json", 7)).not.toThrow();
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
      "queue-v1.json",
      "queue-v2.json",
      "queue-v3.json",
      "results-v1.json",
      "results-v2.json",
      "results-v3.json",
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
    const mutated = readJson("reply-classify", "results-v1.json") as { results: Array<Record<string, unknown>> };
    mutated.results[0].intent = "maybe_interested";
    expect(() => assertReplyClassifyResultsShape(mutated, "results-v1.json", 1)).toThrow(/intent must be one of/);
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
