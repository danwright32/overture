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

# --- the plugin lockout (#1682) -------------------------------------------------------------------------
#
# The tool scope above decides what a detached run may DO. This decides what it is TOLD. Same shape of
# hole, found the same way: a headless `claude -p` loads ~/.claude wholesale, which includes every Claude
# Code plugin enabled on this Mac, and a plugin's SessionStart, UserPromptSubmit and PreToolUse hooks can
# inject whatever text they like into a run this repo believes it wrote the prompt for.
#
# Measured on 2026-07-28 by reading a real run's event stream: a Vercel plugin installed for an unrelated
# project pushed 54,486 characters of Next.js product documentation into EVERY chunk of a contact hunt
# whose whole job was to find one email address, and that text carries imperatives in the same voice the
# runbooks use ("MANDATORY ... You MUST open and read the official docs ... BEFORE writing ANY code",
# "You must run the Skill(...)"). Turning every plugin off cut a trivial run from 53,610 input tokens to
# 45,139, measured both ways on the wire. That run was not derailed, so this is cost and risk rather than
# an active failure, but a prompt that goes to the trouble of forbidding a run from harvesting a venue
# address should not also be carrying a stranger's mandatory instructions.
#
# The two things that make this fiddlier than it looks, both measured rather than assumed:
#
#  1. `--settings` MERGES enabledPlugins PER KEY; it does not replace the object. `{"enabledPlugins":{}}`
#     disables nothing at all, and naming one plugin leaves the other six loaded. So every installed
#     plugin has to be named explicitly.
#  2. The obvious alternative, `--setting-sources project,local`, drops ~/.claude entirely and takes the
#     dan-wright-brand-voice skill with it, silently changing the voice of emails reaching strangers.
#     Disabling plugins does NOT: skills in ~/.claude/skills load from a separate source and survive
#     (verified on the wire). `--bare` also works but never reads OAuth, taking every run off the Max
#     plan and onto a paid API key.
#
# Because the list has to be enumerated, it must be DERIVED from the machine rather than written down
# here. A hardcoded list of whatever is installed today would go stale, silently, the first time a plugin
# is installed, and the run would quietly start carrying it again with every test still green.

# claude_run_plugin_lockout <claude-binary> <label>: emits `--settings <json>` turning off every Claude
# Code plugin installed on this Mac, or REFUSES (returns nonzero, emits nothing) if it cannot establish
# what those are. Refusing is the point: "the plugin list could not be read" and "there are no plugins"
# must never collapse into the same silent outcome, because the second one disables nothing.
claude_run_plugin_lockout() {
  local claude_bin="$1" label="$2"

  if [ -z "${claude_bin}" ] || [ ! -x "${claude_bin}" ]; then
    echo "${label}: refusing to run: no claude binary to enumerate this Mac's plugins with, so they cannot be turned off" >&2
    return 1
  fi

  local listing
  if ! listing="$("${claude_bin}" plugin list --json 2>/dev/null)"; then
    echo "${label}: refusing to run: 'claude plugin list --json' failed, so this Mac's plugins cannot be turned off" >&2
    return 1
  fi

  # It must be the JSON array the command documents. Anything else (an error page, a prompt, a new output
  # format) is unreadable, not empty.
  case "$(printf '%s' "${listing}" | tr -d ' \t\n')" in
    '['*']') ;;
    *)
      echo "${label}: refusing to run: 'claude plugin list --json' did not return a JSON array, so this Mac's plugins cannot be turned off" >&2
      return 1 ;;
  esac

  # One id per plugin object. The braces and commas are turned into newlines first, so each key/value pair
  # stands alone whether the command pretty-printed its JSON or emitted it on one line: an earlier version
  # anchored the match to the start of a line and read nothing at all out of the compact form. Each id
  # must carry the `@marketplace` half every plugin id has, so a nested "id" inside a plugin's own
  # mcpServers block could never be mistaken for a plugin.
  local ids
  ids="$(printf '%s' "${listing}" | tr '{},' '\n\n\n' | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*@[^"]*\)".*/\1/p')"

  # The silent-failure case this exists to catch: the listing holds plugins but the field this parser
  # reads has been renamed or reshaped, so it extracts nothing and would emit a map that turns nothing
  # off while reporting success.
  if [ -z "${ids}" ] && printf '%s' "${listing}" | grep -q '{'; then
    echo "${label}: refusing to run: 'claude plugin list --json' listed plugins but none carried a readable id, so they cannot be turned off" >&2
    return 1
  fi

  # Built with no spaces anywhere: the runners splice this scope onto the command line by deliberate word
  # splitting, and a single space would break the flag into pieces.
  local disabled="" id
  for id in ${ids}; do
    disabled="${disabled}${disabled:+,}\"${id}\":false"
  done

  printf '%s' "--settings {\"enabledPlugins\":{${disabled}}}"
}

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
#   $5 = the claude binary this run will launch, used to enumerate and turn off this Mac's plugins (#1682)
claude_run_scope() {
  local allow="$1" mode="$2" forbidden_tools="$3" label="$4" claude_bin="$5"

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

  # And no plugin installed on this Mac may load into the run. Its refusal sinks the WHOLE scope: a run
  # that started with the tool boundary intact but every plugin still injecting is the #1682 hole itself,
  # and a partial scope is worse than none.
  local lockout
  lockout="$(claude_run_plugin_lockout "${claude_bin}" "${label}")" || return 1

  printf '%s' "--allowedTools ${allow} --permission-mode ${mode} ${lockout}"
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
  claude_run_scope "${PREP_ALLOWED_TOOLS}" "${PREP_PERMISSION_MODE}" "${PREP_FORBIDDEN_TOOLS}" "prep" "${1:-}"
}

# --- reply-classify ------------------------------------------------------------------------------------
# Reply-classify reads the work-list and the voice guidance, classifies each reply, and drafts a reply in
# Dan's voice (docs/reply-classify-runbook.md). It needs Read, Write and Skill (to invoke the brand-voice
# skill, #872) and nothing else: no shell, no editing, no web access at all.
REPLY_CLASSIFY_ALLOWED_TOOLS="Read,Write,Skill"
REPLY_CLASSIFY_PERMISSION_MODE="manual"
REPLY_CLASSIFY_FORBIDDEN_TOOLS="Bash Edit WebFetch WebSearch"

reply_classify_claude_scope() {
  claude_run_scope "${REPLY_CLASSIFY_ALLOWED_TOOLS}" "${REPLY_CLASSIFY_PERMISSION_MODE}" "${REPLY_CLASSIFY_FORBIDDEN_TOOLS}" "reply-classify" "${1:-}"
}
