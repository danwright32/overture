# Sourced (not executed) by prep-run.sh, which is /bin/sh, so everything here stays POSIX.
# Sourced AFTER lib/run-slot.sh and after resolve_run_slot: it reads SUPPORT and slot_others.
#
# #2762 (phase 6 of #2620): did this run share the machine with another run slot?
#
# #1616 taught the selection bar to quote a wait learned from the checks that have actually run, pooling
# the last ten and taking over the pre-spend estimate at three samples. That was right while exactly one
# run could ever be alive. #2620 removes that, so the first three checks that run beside a Prep run would
# quietly retrain the figure Dan reads BEFORE deciding to spend, and it would read as evidence rather than
# as a measurement of a different machine. The app refuses to pool the two classes; this is the half that
# tells it which class a run belongs to.
#
# WHY THE RUNNER AND NOT THE APP. The wall clock this flag qualifies (`runCost.durationMs`) is the
# runner's own recording, and the runner is the only thing alive for the whole span. An app-side observer
# would be a second source for a second fact about one run, and the two would disagree exactly when it
# matters: a prep that starts and ends between two of the app's ticks is invisible to it and real to the
# check that was slowed down by it (L70).
#
# WHAT COUNTS, and it is narrow on purpose: another RUN SLOT. Not "the machine was busy". A scout extract
# (up to four claudes, fired hourly by autoScoutIfDue) or a reply classify can be going too, and folding
# those in would give the stored flag two meanings depending on which version wrote the row, since every
# row already on disk predates the wider definition (L118). #2762's measurement session counts those
# directly instead, which is the right instrument for a question about the whole machine.

# The slots that are not this one, by name. Derived from slot_others, so a third slot cannot leave a run
# unchecked against it: a list written out here only ever holds what somebody remembered (L96).
#
# NAMES, never paths. The live support directory is "~/Library/Application Support/Overture", so an
# unquoted expansion of a path word-splits on that space and matches nothing while looking exactly like it
# worked, which is the trap lib/run-slot.sh already documents for its chunk wipe.
contention_others() {
  slot_others
}

# Latch what is alive right now. Called once before the work starts and again on every marker tick, so a
# run that shared the machine for any part of its span is recorded as contended.
#
# LATCHED rather than read at the end, because contention is a fact about the whole span: a prep that
# starts and finishes inside a six minute check really did share the machine with it, and asking the
# question afterwards would answer no.
#
# Its OWN marker is never counted, which is not a nicety: prep-run.sh writes that marker before the work
# begins, so a rule reading "any -running file" would report every run as contended and the flag would
# carry no information at all. slot_others is what makes that structural rather than remembered.
contention_observe() {
  contention_state="$1"
  for contention_other in $(contention_others); do
    if [ -e "${SUPPORT}/${contention_other}-running" ]; then
      printf '%s\n' "${contention_other}" >> "${contention_state}"
    fi
  done
}

contention_observed() {
  [ -s "$1" ]
}

# The names, deduplicated: a six minute run ticks six times and would otherwise name one prep six times.
contention_names() {
  sort -u "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'
}
