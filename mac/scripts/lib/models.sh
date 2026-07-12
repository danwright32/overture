#!/usr/bin/env bash
# #804: which model each detached run uses, in ONE place.
#
# Every runner used to invoke `claude -p` with no --model flag, so it silently inherited whatever the
# Claude Code CLI default happened to be on Dan's machine that day.
#
# For the mechanical runs that was only money. For DRAFTING it was his voice: those are the words that
# reach a stranger. A CLI upgrade, a settings change or a new default tier could have altered how every
# email he sends sounds, with no code change, no commit and no warning, and nothing recorded which model
# wrote a draft, so he would have found out by noticing his emails reading differently.
#
# One file, because a model choice that is right in two scripts and wrong in the third is the same bug
# wearing a disguise.

# Drafting. Dan's call (2026-07-12): the TIER is pinned, not the exact version, so he picks up each new
# Opus as it ships. He accepted that his voice can shift with a new model in exchange for the
# improvement, and that trade is only reasonable because the model used is now RECORDED below: he can
# tell what wrote a draft rather than merely sensing that something changed.
OVERTURE_MODEL_DRAFTING="opus"

# The mechanical runs. Reading a page for its listings and classifying a reply's intent are tasks with a
# strict output schema and no judgment, which is exactly the cheap-fast-model case. Drafting is exactly
# not, and nothing about that distinction was ever deliberate before: it was inherited.
OVERTURE_MODEL_EXTRACTION="haiku"
OVERTURE_MODEL_REPLY_CLASSIFY="haiku"

# Records the model a run actually used, into that run's own results file.
#
# The SCRIPT records it, not the model, and that is the point: asking a model to write down which model
# it is invites it to be confidently wrong about the one fact the record exists to establish. The script
# passed --model, so the script knows.
#
# Silent on a run that produced no results file: that is already reported loudly elsewhere (the app
# treats a finished-but-empty run as a named failure), and a second complaint from here would just be
# noise on a path that is already handled.
record_model() {
  local results="$1" model="$2"
  [[ -f "${results}" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  node -e '
    const fs = require("fs");
    const [file, model] = process.argv.slice(1);
    try {
      const json = JSON.parse(fs.readFileSync(file, "utf8"));
      json.model = model;
      fs.writeFileSync(file, JSON.stringify(json, null, 2));
    } catch (e) {
      // A results file we cannot parse is the run having failed, which is reported on its own path.
      // Losing the model stamp is not worth turning that into a second, more confusing failure.
    }
  ' "${results}" "${model}" || true
}
