# Sourced (not executed) by mac/build-install.sh and mac/scripts/run-debug.sh.
#
# #2838: point a build's preferences domain at THIS checkout's three detached runner scripts.
#
# WHY IT EXISTS. The app finds each runner script through an absolute path stored in UserDefaults, one
# key per script per bundle identity: six entries, every one of them the same checkout path with a
# different filename on the end. They live OUTSIDE the repo, so no code change, test or guard in this
# repository can notice one has gone stale, and moving the checkout invalidates all six at once. Until
# now the only way to set them was by hand, from a runbook holding a literal path (`docs/scout-extract-
# runbook.md` spelled Dan's out five times). That is L153: a path recording where something HAPPENED to
# be rather than what it is.
#
# The two scripts that source this are the two things that already KNOW where the checkout is, because
# they are running from inside it. So the values are derived rather than typed, and a move plus a
# reinstall corrects every one of them with nobody editing anything.
#
# It is only half the answer, deliberately. The app ALSO derives these paths from `installed-build.json`'s
# `repoPath` when the stored value names nothing runnable (`RunnerScripts.resolve`), which is what covers
# the window between a move and the next install. This half is what stops the stored values being wrong
# in the first place; that half is what stops a wrong one mattering.
#
# POSIX sh, because check-runner-posix.sh requires every helper under mac/scripts that a /bin/sh script
# sources to parse under sh.

# write_runner_defaults <bundle-id> <repo-root>: writes the three runner script paths into that domain.
#
# It writes rather than skipping an existing value, on purpose: a stale value is exactly what this is
# here to correct, and an install from a checkout is an unambiguous statement of which checkout the app
# should be reading. Anyone deliberately pointing a build at another checkout's scripts sets the key
# again afterwards, which is the same thing they do today.
write_runner_defaults() {
  runner_defaults_domain="$1"
  runner_defaults_repo="$2"

  if [ -z "${runner_defaults_domain}" ] || [ -z "${runner_defaults_repo}" ]; then
    echo "write_runner_defaults: needs a bundle id and a repo root, got '${runner_defaults_domain}' and '${runner_defaults_repo}'." >&2
    return 1
  fi

  # The pairs, as "<defaults key> <script filename>". These names are the app's:
  # `RunnerScripts.Runner` in mac/Overture/Domain/RunnerScripts.swift owns both halves, and
  # runner-defaults.test.sh checks this list against that file rather than against memory, so a runner
  # added there and forgotten here fails rather than silently never being configured (L96).
  while read -r runner_defaults_key runner_defaults_script; do
    [ -n "${runner_defaults_key}" ] || continue
    runner_defaults_path="${runner_defaults_repo}/mac/scripts/${runner_defaults_script}"
    # Refuse rather than record a path to nothing. A stored value naming a missing script is the state
    # this whole change exists to stop producing, so writing one here would be the defect wearing the
    # fix's clothes (L12, report what verifiably happened).
    if [ ! -f "${runner_defaults_path}" ]; then
      echo "==> Not pointing ${runner_defaults_domain} at ${runner_defaults_key}: no script at ${runner_defaults_path}" >&2
      continue
    fi
    chmod +x "${runner_defaults_path}" 2>/dev/null || true
    defaults write "${runner_defaults_domain}" "${runner_defaults_key}" "${runner_defaults_path}"
  done <<'RUNNER_DEFAULTS_PAIRS'
prepRunnerScriptPath prep-run.sh
replyClassifyRunnerScriptPath reply-classify-run.sh
scoutExtractRunnerScriptPath scout-extract-run.sh
RUNNER_DEFAULTS_PAIRS

  echo "==> Pointed ${runner_defaults_domain} at the runner scripts in ${runner_defaults_repo}"
}
