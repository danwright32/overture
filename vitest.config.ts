import { defineConfig } from "vitest/config";

// #3120: name where this repo's tests are, rather than taking vitest's default include.
//
// `vitest run` with no config uses `**​/*.{test,spec}.?(c|m)[jt]s?(x)`, excluding only node_modules,
// dist and similar. This repo runs parallel agents in git worktrees under `.claude/worktrees/`, and each
// is a FULL checkout, so each contributed its own copy of every test file. Measured 2026-08-22 in the
// ordinary working checkout: 16 real test files, 14 worktrees, `Test Files  240 passed (240)`.
//
// Neither consequence looked like a failure. A half finished branch in a worktree contributed its
// failing tests to the verdict on whoever ran `pnpm test` in the parent checkout, and the count read as
// thorough while moving with how many agents happened to be running. `pnpm test` is one of the two cheap
// lanes in `scripts/test-all.sh`, which AGENTS.md requires before every push, so this ran constantly.
//
// An INCLUDE rather than an exclude for `.claude/worktrees`, deliberately: an include anchored inside
// this repo's own directories cannot be defeated by a future worktree folder with a different name, and
// an exclude can. `tsconfig.json` already names its directories the same way, which is why
// `pnpm typecheck` never had this defect, and so does `scripts/run-shell-fixtures.sh`.
//
// `src/lib/testDiscoveryScope.test.ts` guards both halves: that the include stays anchored, and that no
// test file of this repo's own is left outside where it looks.
export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
  },
});
