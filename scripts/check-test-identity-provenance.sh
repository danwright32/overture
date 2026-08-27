#!/usr/bin/env bash
set -euo pipefail

# #3110 / #3131 / #3140: which names in this repository's test data belong to a real person?
#
# TWO ROUTES IN, and #3140 is the second. An identity reaches test data as an ADDRESS (whose local part
# and domain label are both read below) or as a URL HOST, and until #3140 nothing looked at a URL at all.
# Measured 2026-08-22 over the scanned roots: 201 distinct hosts appear in `http(s)://` URLs and 102 of
# them are on registrable domains rather than a reserved TLD. Most are platforms, ticketing hosts and
# public venues; at least eight are shaped like one private individual's own name plus a real TLD, and
# one of those belonged to a person this repository had already decided to remove.
#
# WHAT #2839 LEFT OPEN. `TestDataEmailDomainGuardTests` judges an address by its DOMAIN: anything on a
# reserved TLD (.example, .invalid, .test) or example.com passes, because such a domain can never be
# registered by anybody. That closes the deliverability half and leaves the identity half wide open,
# because `arealpersonsname.example` is reserved and still names a real person in a PUBLIC repository.
# It is not hypothetical: two were in the tree when that guard was written, both a real performer's own
# name moved onto a reserved TLD by an earlier partial scrub, and #2839 replaced only the domain, so a
# scrubbed person's name routinely survived as the LOCAL PART of the very address that replaced it.
#
# WHY THIS IS NOT A PER-PUSH GATE, and why it is not a regex either. #3110 named two candidate answers
# and asked for one to be measured before choosing. Neither of them is what shipped:
#
#   Checking the domain label against the display names in the same file was rejected because it does
#   not discriminate. An INVENTED personal-name domain appears as a display name in its own test just as
#   reliably as a real one does, so the rule fires identically on both, and a rule that fires on the
#   correct fix is one that gets switched off (L93).
#
#   A periodic AI review over the corpus was rejected because a cheaper answer turned out to exist, and
#   because a judgement nothing records is one the next sweep repeats from scratch.
#
# WHAT SHIPPED INSTEAD is evidence rather than a pattern, and it was measured before it was built: a
# name whose FIRST APPEARANCE in this repository is a privacy scrub commit was MINTED by that scrub and
# is therefore invented, and a name whose first appearance is an ordinary feature commit was written
# from real data by somebody who had a real page open. Measured 2026-08-22, `git log -S<name> --reverse`
# separated all eighteen names scrubbed in #2834 (every one first added by a feature commit) from
# `Corin Hale` and `Nora Calder`, which were about to be scrubbed by mistake and had been minted by
# #2839 and #2844. This script is that lookup, over every identity a reserved-domain address carries.
#
# IT REPORTS, IT DOES NOT REFUSE, and that is deliberate rather than timid. Plenty of feature-introduced
# names are perfectly invented, so a gate on "introduced by a feature commit" would fire on the common
# case. What it produces is a list of identities NOBODY HAS LOOKED AT YET, each carrying the commit that
# introduced it, so the judgement is made once and recorded instead of being remade every sweep.
#
# THE BASELINE GROWS, unlike fixtures/test-data-email-domains.txt, which may only shrink. That file is a
# ratchet over a defect being paid off; this one is a triage log over identities somebody has read. New
# invented identities legitimately arrive with new tests, and recording one is the act of having looked
# at it. --record prints what it is about to add for exactly that reason: recording without seeing the
# list is how a count driven to zero stops being read as a measurement (L182).
#
# COST, and why it is not in scripts/test-all.sh. It runs one `git log -S` per identity over the whole
# history, which is roughly two thirds of a second each. Run it after a sweep, after adding test data
# that carries names, and periodically.

usage() {
  cat <<'USAGE'
usage: scripts/check-test-identity-provenance.sh [--record]

  (no flags)  Report every identity in reserved-domain test data that the baseline has not recorded,
              each with the commit that introduced it, plus any baseline line whose identity is gone.
  --record    Write the baseline to exactly what is in the tree now, printing what it adds.

exit status
  0  measured, and every identity present is already recorded
  1  measured, and there are identities to triage (or baseline lines to delete)
  2  UNMEASURED: nothing was extracted at all, so nothing was checked

environment
  OVERTURE_IDENTITY_REPO      repository to scan (default: this script's own repository)
  OVERTURE_IDENTITY_ROOTS     space separated paths inside it (default: the test data roots)
  OVERTURE_IDENTITY_BASELINE  the triage log (default: <repo>/fixtures/test-identity-provenance.txt)
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${OVERTURE_IDENTITY_REPO:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
ROOTS="${OVERTURE_IDENTITY_ROOTS:-mac/OvertureTests mac/OvertureHostedTests mac/TestSupport fixtures}"
BASELINE="${OVERTURE_IDENTITY_BASELINE:-${REPO}/fixtures/test-identity-provenance.txt}"

RECORD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --record) RECORD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Every identity a reserved-domain address carries, which is BOTH of its halves. Reading only the domain
# is what #2839 did, and a scrub that replaces only the domain leaves the person's own name as the local
# part of the address that replaced it, so a reader of one half reports a scrub as complete when half of
# it has happened.
#
# The token is kept VERBATIM apart from lowercasing, punctuation included. Normalising
# `marguerite.eddowes` to `margueriteeddowes` looks like tidying and is the one change that breaks the
# whole mechanism: `git log -S` searches for a literal string, so a normalised token is in no commit
# anywhere, and the lookup then answers "no commit found" for exactly the punctuated identities, in
# wording that reads as a shrug rather than as the tool having asked the wrong question. Three of the
# 264 identities in this repository did that before this line was removed.
#
# There is deliberately no stoplist of boring words. `press`, `boxoffice` and `hall` are not identities,
# and they are reported on the first run and absorbed by the baseline once. A stoplist would only ever
# hold what somebody remembered, and its failure direction is the silent one (L96): over-reporting costs
# one line in a file, under-reporting hides a person.
extract_identities() {
  local root missing=0 present=0
  for root in ${ROOTS}; do
    if [[ ! -d "${REPO}/${root}" ]]; then missing=$(( missing + 1 )); continue; fi
    present=$(( present + 1 ))
  done
  if [[ "${present}" -eq 0 ]]; then return 0; fi
  local paths=()
  for root in ${ROOTS}; do
    if [[ -d "${REPO}/${root}" ]]; then paths+=("${REPO}/${root}"); fi
  done
  # Both extractions below feed ONE sort at the end of the function, not one each. They are compared
  # against the baseline with `comm`, which requires sorted input and answers nonsense rather than
  # failing when it does not get it: two locally sorted lists concatenated are not a sorted list.
  #
  # `|| true` because grep answers "no matches" with exit 1, which is not a failure here: it is the
  # UNMEASURED case, and it has to reach the caller as an empty result rather than as an abort that
  # never gets to say so.
  {
  { grep -rhoaE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "${paths[@]}" 2>/dev/null || true; } \
    | awk '
        BEGIN {
          split("example invalid test localhost local", t, " ")
          for (i in t) reservedTLD[t[i]] = 1
          split("example.com example.org example.net", d, " ")
          for (i in d) reservedDomain[d[i]] = 1
        }
        {
          addr = tolower($0)
          at = index(addr, "@")
          if (at == 0) next
          localPart = substr(addr, 1, at - 1)
          domain = substr(addr, at + 1)
          n = split(domain, labels, ".")
          if (!(domain in reservedDomain) && !(labels[n] in reservedTLD)) next
          print localPart
          print labels[1]
        }' \
    | sort -u \
    | sed '/^$/d'

  # #3140: the OTHER way a real person reaches test data, and the one neither guard could see.
  #
  # `TestDataEmailDomainGuardTests` judges an ADDRESS by its domain and the extraction above reads the
  # identities inside a RESERVED-domain address. Neither looks at a URL, and a URL is how a real person
  # most often reaches this data, because a contact route in the live store is a form on somebody's own
  # site far more often than it is an address. `PressContactFormGuardTests` says so in its own comment:
  # its list is "every other form in the live store, which must all stay usable", so the test data is a
  # verbatim extract of Dan's real prospect contact routes, in a PUBLIC repository.
  #
  # The exposure #2831 and #2839 exist to close is the PERSON, not the deliverability of an address. A
  # repository stating that a named musician is a prospect of Dan's exposes the same thing whether it
  # states it with an address or with a link to their contact page.
  #
  # THE REGISTRABLE LABEL, and only it. A reserved TLD is invented by construction and is already the
  # safe case, so it is skipped here exactly as it is KEPT above: the two halves want opposite sets,
  # because a reserved-domain ADDRESS can still carry a real name in its local part while a
  # reserved-domain HOST cannot be anybody's real site. `www` is stripped so one site is one identity.
  #
  # Deliberately NO judgement here about whether a label looks like a person's name. #3110 measured that
  # question and it does not discriminate: an invented personal-name host appears exactly as a real one
  # does. What discriminates is the same evidence the addresses use, the commit that introduced it, so a
  # platform, a public venue and a private individual all go through one lookup and the answer is read
  # per identity rather than guessed from the spelling.
  { grep -rhoaE 'https?://[A-Za-z0-9.-]+' "${paths[@]}" 2>/dev/null || true; } \
    | awk '
        BEGIN {
          split("example invalid test localhost local", t, " ")
          for (i in t) reservedTLD[t[i]] = 1
        }
        {
          host = tolower($0)
          sub(/^https?:\/\//, "", host)
          sub(/^www\./, "", host)
          n = split(host, labels, ".")
          if (n < 2) next
          if (labels[n] in reservedTLD) next
          # EVERY label but the TLD, rather than a guess at which one is registrable. There is no way to
          # know that without a public suffix list: `wraymoorhall.co.uk` puts the name two labels from
          # the end and `pellingborne.org` puts it one, and picking the wrong one hides the person. So it
          # over-reports, in the same direction and for the same reason the extraction above keeps no
          # stoplist of boring words: `tickets` and `co` are not identities and are absorbed by the
          # baseline once, while under-reporting hides somebody and nothing ever says so (L96).
          for (i = 1; i < n; i++) if (labels[i] != "www") print labels[i]
        }'
  } | sort -u | sed '/^$/d'
}

# The commit in which this identity FIRST appears anywhere under the scanned roots. `--reverse` after
# the fact rather than `-n 1`, because git applies a count BEFORE reversing and would answer with the
# most recent commit to touch the token, which is the opposite of what is being asked.
# The commit in which this identity FIRST appears ANYWHERE in this repository.
#
# `--reverse` after the fact rather than `-n 1`, because git applies a count BEFORE reversing and would
# answer with the most recent commit to touch the token, which is the opposite of what is being asked.
#
# Deliberately NOT scoped to the roots being scanned, even though scoping is the obvious thing to do and
# is faster. A pathspec does not follow a rename, so a fixture written somewhere else and later moved
# under a scanned root has its MOVE reported as its origin: the token genuinely first appears at that
# path in the commit that put it there. That answer is wrong in the direction that matters, because a
# move is very often part of a tidy-up and reads as recent and deliberate, while the real write may be a
# year older and made from a real page. Measured in this script's own fixture, where the scoped lookup
# named the move commit and the unscoped one named the write.
#
# NOT RESOLVED is its own outcome and is worded as a refusal, not as a shrug: an identity nothing in the
# history accounts for is the most interesting one on the list, not the least (L11).
introducing_commit() {
  local token="$1" all first
  all="$(git -C "${REPO}" log -S"${token}" --reverse --format='%h %ad %s' --date=short 2>/dev/null || true)"
  if [[ -z "${all}" ]]; then
    echo "PROVENANCE NOT RESOLVED: no commit in this history adds this identity. It is uncommitted, or"
    echo "                        it reaches the tree by a route this lookup cannot see. Read it by hand."
    return
  fi
  first="${all%%$'\n'*}"
  echo "${first}"
}

read_baseline() {
  if [[ ! -f "${BASELINE}" ]]; then return 0; fi
  sed 's/#.*//' "${BASELINE}" | tr -d ' \t' | sort -u | sed '/^$/d'
}

PRESENT="$(extract_identities)"

if [[ -z "${PRESENT}" ]]; then
  cat >&2 <<EOF
UNMEASURED: no identity was extracted from any of the scanned roots, so nothing was checked.

  repository: ${REPO}
  roots:      ${ROOTS}

An empty extraction and a tree with genuinely nothing to look at leave the same empty result, and the
emptiest possible failure must never read as the cleanest possible pass (L98). Check the roots exist and
hold test data before reading this as clean.
EOF
  exit 2
fi

KNOWN="$(read_baseline)"
FRESH="$(comm -23 <(printf '%s\n' "${PRESENT}") <(printf '%s\n' "${KNOWN}"))"
GONE="$(comm -13 <(printf '%s\n' "${PRESENT}") <(printf '%s\n' "${KNOWN}"))"

if [[ "${RECORD}" -eq 1 ]]; then
  if [[ -n "${FRESH}" ]]; then
    echo "Recording $(printf '%s\n' "${FRESH}" | wc -l | tr -d ' ') identity(ies) as triaged:"
    printf '%s\n' "${FRESH}" | sed 's/^/  + /'
  fi
  if [[ -n "${GONE}" ]]; then
    echo "Dropping $(printf '%s\n' "${GONE}" | wc -l | tr -d ' ') identity(ies) that are no longer present:"
    printf '%s\n' "${GONE}" | sed 's/^/  - /'
  fi
  {
    cat <<'HEADER'
# Identities in reserved-domain test data that somebody has looked at (#3110, #3131).
#
# One token per line: the local part or the first domain label of an address whose domain can never be
# registered by anybody. A line here means a person read that identity's introducing commit and judged
# it invented, or judged that it names a public entity rather than a private individual.
#
# This file GROWS. It is a triage log, not a ratchet: new invented identities arrive with new tests, and
# recording one is the act of having looked at it. fixtures/test-data-email-domains.txt is the ratchet,
# and that one may only shrink.
#
# WHAT THE FIRST RECORDING ACTUALLY READ, stated here rather than left to be assumed, because a header
# that claims more than was done stops the next look from happening (#3133 is that defect, one file
# over). Of the 266 identities below, the ones shaped like a person's full name AND introduced by an
# ordinary feature commit were read one by one against the fixture they sit in: that is the class that
# can hold a real person. Two were found and scrubbed. The remainder are placeholders (`a`, `x`, `zzz`),
# roles (`press`, `boxoffice`, `producer`), venues and ensembles, and names minted by a privacy scrub,
# and those were read as groups rather than one at a time.
#
# WHAT IS OUT OF SCOPE HERE, so that its absence is not read as its having been cleared: this file
# covers e-mail addresses on domains nobody can register. A real person named by a URL on a REGISTRABLE
# domain is a separate class that no guard in this repository sees, and it is filed separately.
#
# Regenerate with: scripts/check-test-identity-provenance.sh --record
# Read the list it prints before you commit the result. Recording without reading is how a check stops
# being a measurement.
HEADER
    printf '%s\n' "${PRESENT}"
  } > "${BASELINE}"
  echo "Wrote ${BASELINE}"
  exit 0
fi

STATUS=0

if [[ -n "${FRESH}" ]]; then
  STATUS=1
  echo "$(printf '%s\n' "${FRESH}" | wc -l | tr -d ' ') identity(ies) in test data (reserved-domain addresses and URL hosts) that nobody has triaged yet."
  echo
  echo "A name whose first appearance is a privacy SCRUB commit was minted by that scrub and is invented."
  echo "A name whose first appearance is an ordinary FEATURE commit was written from real data: read it."
  echo
  while IFS= read -r token; do
    printf '  %s\n      first appears in  %s\n' "${token}" "$(introducing_commit "${token}")"
  done <<< "${FRESH}"
  echo
  echo "Scrub the ones that name a real person. Record the rest with --record, having read this list."
fi

if [[ -n "${GONE}" ]]; then
  STATUS=1
  echo
  echo "$(printf '%s\n' "${GONE}" | wc -l | tr -d ' ') recorded identity(ies) no longer appear in any scanned test data:"
  printf '%s\n' "${GONE}" | sed 's/^/  /'
  echo
  echo "Delete those lines with --record. A log that still describes a tree it no longer matches hides a"
  echo "re-introduction behind a line that looks already answered."
fi

if [[ "${STATUS}" -eq 0 ]]; then
  echo "Every identity in reserved-domain test data is already recorded ($(printf '%s\n' "${PRESENT}" | wc -l | tr -d ' ') of them)."
fi
exit "${STATUS}"
