import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// #380: engine-side counterpart to mac/OvertureTests/UserFacingDashGuardTests.swift. Dan's
// writing rule bans em/en dashes used as a parenthetical break or connector anywhere, including
// code comments and console output, not just user-facing copy. Scans the engine's own source
// (src/lib and scripts, "the scout engine" per AGENTS.md) but not test files, which may
// legitimately need one in fixture data modeling messy real-world input.
const EM_DASH = "—";
const EN_DASH = "–";
const FORBIDDEN_DASHES = [EM_DASH, EN_DASH];

// The regex character class mirroring the Swift-side separator match (GroupNameMatch.swift) has
// to contain the literal dash characters it matches against.
const ALLOWLISTED_LINES = new Set(["groupNameMatch.ts:11"]);

function tsSourceFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      out.push(...tsSourceFiles(full));
    } else if (entry.endsWith(".ts") && !entry.endsWith(".test.ts")) {
      out.push(full);
    }
  }
  return out;
}

function findForbiddenDashes(dirs: string[]): string[] {
  const offenders: string[] = [];
  for (const dir of dirs) {
    for (const path of tsSourceFiles(dir)) {
      const name = path.split("/").pop()!;
      const lines = readFileSync(path, "utf8").split("\n");
      lines.forEach((line, idx) => {
        const lineNo = idx + 1;
        if (ALLOWLISTED_LINES.has(`${name}:${lineNo}`)) return;
        if (FORBIDDEN_DASHES.some((d) => line.includes(d))) {
          offenders.push(`${name}:${lineNo}  ${line.trim()}`);
        }
      });
    }
  }
  return offenders;
}

describe("no forbidden em/en dashes in engine source (#380)", () => {
  it("has none outside the one line that has to contain a literal dash", () => {
    const libDir = fileURLToPath(new URL(".", import.meta.url));
    const scriptsDir = fileURLToPath(new URL("../../scripts/", import.meta.url));
    const offenders = findForbiddenDashes([libDir, scriptsDir]);
    expect(offenders).toEqual([]);
  });
});
