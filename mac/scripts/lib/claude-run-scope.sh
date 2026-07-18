# #1097: the tool scope for the DETACHED claude runs, in ONE place, shared by all three runners
# (scout-extract, prep, reply-classify).
#
# Every one of these runs is launched headless by the app, reads content the app fetched or a stranger
# wrote, and writes the data Dan later acts on. None is supervised. Each needs a FIXED, small set of
# tools, and nothing else.
#
# The bug this guards against is invisible from the allowlist alone (#1026). Passing only
# `--allowedTools "..."` PRE-APPROVES those tools; it does not RESTRICT to them. A headless `claude -p`
# inherits the same ~/.claude settings an interactive session has, where `permissions.defaultMode` is
# "auto", and under auto every OTHER tool (Bash, Edit, Skill, WebSearch, anything the environment exposes)
# is auto-approved too. A 2026-07-17 scout run made 13 Bash and 14 Edit calls with ZERO denials, on a run
# whose comment claimed "No Bash". The fix is `--permission-mode manual`, which OVERRIDES the inherited
# auto: anything outside the allowlist needs an approval a detached run can never give, so it is DENIED
# (it does not hang; the run continues and finishes). Verified by hand on 2026-07-17: with manual, a Bash
# `touch` and an Edit were both blocked while a Write still succeeded; without the mode flag the same Bash
# `touch` ran. So the mode flag, not the allowlist, is what makes the stated posture real.
#
# scout-extract found this first (#1026) and had its own copy of the guard; #1097 routes prep and
# reply-classify through the SAME generic guard rather than copying it a second and third time, so the
# fail-closed posture cannot be right in one runner and a drifted near-copy in another (the exact defect
# #1073/#982 warn about). scout-tools.sh now delegates to this file too.

# The permission modes that leave tools OUTSIDE the allowlist reachable. Under any of these (or an empty
# mode, which falls back to the inherited "auto") a detached run auto-approves Bash, Edit, and the rest,
# so the allowlist is a pre-approval and not a restriction. "manual" and "plan" instead require an
# approval no detached run can supply, making the allowlist a real boundary.
CLAUDE_RUN_UNSAFE_MODES="auto bypassPermissions dontAsk acceptEdits"

# Emits the claude flags (--allowedTools <list> --permission-mode <mode>) that scope a detached run, and
# REFUSES (returns nonzero, emits nothing) if the scope has drifted into an unsafe posture: an
# auto-approving (or empty) permission mode, or a forbidden tool smuggled into the allowlist. Failing loud
# here is deliberate: a partial or unsafe scope is worse than none, because it would silently hand a
# detached run reading untrusted content a shell again.
#
#   $1 = allowlist, comma-separated (e.g. "Read,Write,WebFetch")
#   $2 = permission mode (must be a fail-closed one; "manual" for every current runner)
#   $3 = forbidden tools, space-separated: tools that must NEVER appear in the allowlist, enumerated so a
#        later edit that adds one is caught here instead of in production
#   $4 = a short label naming the run, for the refusal message
claude_run_scope() {
  local allow="$1" mode="$2" forbidden_tools="$3" label="$4"

  # The mode must not be empty (which falls back to the inherited auto) or any approve-everything mode.
  if [ -z "${mode}" ]; then
    echo "${label}: refusing to run: no permission mode set (an empty mode inherits the auto-approve default)" >&2
    return 1
  fi
  local unsafe
  for unsafe in ${CLAUDE_RUN_UNSAFE_MODES}; do
    if [ "${mode}" = "${unsafe}" ]; then
      echo "${label}: refusing to run: permission mode '${mode}' auto-approves tools outside the allowlist" >&2
      return 1
    fi
  done

  # No forbidden tool may appear in the allowlist. Compared with commas around both sides so "WebFetch"
  # can never match "WebSearch" and "Read" can never match a substring of another tool name.
  local forbidden
  for forbidden in ${forbidden_tools}; do
    case ",${allow}," in
      *",${forbidden},"*)
        echo "${label}: refusing to run: '${forbidden}' must never be in the ${label} allowlist" >&2
        return 1 ;;
    esac
  done

  printf '%s' "--allowedTools ${allow} --permission-mode ${mode}"
}

# --- prep ----------------------------------------------------------------------------------------------
# Prep finds a contact and drafts an email per prospect (docs/prep-runbook.md). It DELIBERATELY needs Bash
# and Skill (it does web research and invokes the dan-wright-brand-voice skill), so this is not a copy of
# the scout posture: what the mode must still deny is everything ELSE, Edit above all (the tool the
# 2026-07-17 run abused 14 times). Overridable so the guard's failure paths can be exercised by a test.
PREP_ALLOWED_TOOLS="Read,Write,WebSearch,WebFetch,Bash,Skill"
PREP_PERMISSION_MODE="manual"
PREP_FORBIDDEN_TOOLS="Edit"

prep_claude_scope() {
  claude_run_scope "${PREP_ALLOWED_TOOLS}" "${PREP_PERMISSION_MODE}" "${PREP_FORBIDDEN_TOOLS}" "prep"
}

# --- reply-classify ------------------------------------------------------------------------------------
# Reply-classify reads the work-list and the voice guidance, classifies each reply, and drafts a reply in
# Dan's voice (docs/reply-classify-runbook.md). It needs Read, Write and Skill (to invoke the brand-voice
# skill, #872) and nothing else: no shell, no editing, no web access at all.
REPLY_CLASSIFY_ALLOWED_TOOLS="Read,Write,Skill"
REPLY_CLASSIFY_PERMISSION_MODE="manual"
REPLY_CLASSIFY_FORBIDDEN_TOOLS="Bash Edit WebFetch WebSearch"

reply_classify_claude_scope() {
  claude_run_scope "${REPLY_CLASSIFY_ALLOWED_TOOLS}" "${REPLY_CLASSIFY_PERMISSION_MODE}" "${REPLY_CLASSIFY_FORBIDDEN_TOOLS}" "reply-classify"
}
