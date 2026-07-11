# Performer-name match fixture (#749, plan #748, issue #585)

Repeat-client detection has always matched on the org or group name only, so a performance whose
group name is new but whose *performer* is someone Dan has already shot scored as a cold lead
(#585). `HistoryMatch.matchPerformer` closes that gap at Prep time: it matches a performer's name
against the canonical Downbeat clients and the imported booking history, and returns a positive
relationship when it is confident.

`v1.json` is the locked spec for that behavior, decoded and asserted by
`mac/OvertureTests/PerformerMatchTests.swift`. It carries a `clients` list, a `history` list, and a
`cases` table of inputs (performer name, performer email, production) to the expected verdict.

Three properties this fixture exists to hold still, because each one is load-bearing and easy to
regress by "improving" the matcher:

1. **Person names are matched more strictly than org names.** `GroupNameMatch.isConfident` accepts
   token *containment* (so "New York Ballet" matches "New York Theatre Ballet"), which is right for
   orgs and wrong for people: it would match the person "Jane Doe" to the org "Jane Doe Ensemble".
   The person-name path requires full token-set equality instead. Token *order* still does not
   matter, so a surname-first program listing ("Vega, Marisol") matches.
2. **A conflicting email suppresses an otherwise-good name match.** Two different people share a
   name more often than one person changes their email, so a mismatch between the performer's email
   and the address on file is treated as evidence against the match, and nothing is auto-corrected
   (Dan's call, precision-first). An empty address on either side is not a conflict; the name alone
   decides. As of #762 this applies to the booking history as well as the Downbeat client list, and
   the history is where it matters most: it is older and broader than the client list, so a name hit
   in it is the one most likely to be a different person who merely shares the name. A conflict on
   ANY name-matching record suppresses the whole match, rather than just dropping that record;
   otherwise the match walks back in through a quieter row carrying no address, and the rule is
   silently defeated.
3. **This path can never suppress a performance.** It is positive-match-only by construction: the
   verdict has no `suppressed` field, so a do-not-contact record reached through a performer name
   neither drops the performance nor lends it a positive relationship. Do-not-contact suppression
   remains the org-level `HistoryMatch.matchRelationship`'s job alone.
4. **Only a relationship worth more than a cold lead counts as a match at all** (#763, the
   upgrade-only floor). A performer whose only history is a `contacted` row (a cold send that got
   silence, worth 0 points) is NOT a match: correcting it would move the score by nothing while still
   setting the sticky lock and raising a flag for Dan, which is how you teach someone to ignore the
   flag. A `lost_hard` row (worth -20) is not a match either; a warm-lead detector has no business
   quietly downgrading a lead. The floor is read off `Ranker.priorPoints`, not a hardcoded status
   list, so it stays honest if the ranker's weights are ever retuned.

Three further rules exist ONLY because the #755 precision check ran the matcher against Dan's real
Downbeat clients and booking history, where it initially matched just 2 of 13 known past performers.
Each is a concession to how his history is actually written, and each is deliberately narrow enough
to leave the traps in rule 1 intact:

5. **A trailing instrument or voice part is not part of a name.** His history files a soloist as
   "Kento Hong, violin", so a strict rule could never match the person to the record that IS him. A
   CLOSED vocabulary of role words, not "drop the last token": dropping blindly would turn the org
   "Jane Doe Ensemble" into the person "Jane Doe", which is precisely the false positive rule 1
   exists to stop. Never strips a name below two tokens.
6. **Every line of a multi-line entry is its own candidate person.** He files a two-soloist recital
   as one entry with a performer per line, and the org path only ever reads the org line, so the
   second soloist sat on a line nothing looked at.
7. **Accents fold to plain letters.** `normalize` strips everything outside `a-z`, so "Asunción"
   shredded into the junk tokens "asunci" and "n" and could not match even itself. In classical music
   an accented name is most of the roster, not an edge case.

Together those took the real-data result from 2/13 to 10/13 with both traps still rejecting. The
remaining misses are names buried inside a program title ("American Recital Debut Award Recital
(Sydney Lee)"). Catching those needs a name-appears-anywhere-inside rule, which is exactly what would
match "Abby Whiteside" to her namesake foundation, so they are accepted as misses on purpose.

The production gate is enforced inside the matcher rather than at the call site: an agency-produced
or unknown-production performance returns no match without ever being compared, so a future caller
cannot forget to check.

Sibling of `fixtures/group-name-match/`, which locks the org-name matcher this one deliberately
diverges from. Neither is a cross-language contract (see `docs/contracts.md` for those); both are
internal locked specs for Swift logic that is too important to let drift silently.
