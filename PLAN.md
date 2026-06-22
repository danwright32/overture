# Overture: Plan

Overture is an outreach system for Dan Wright Photography. It finds performing arts organizations and performances worth pitching, finds the right person to contact, drafts an email in Dan's voice, and queues it for Dan to approve and send. Dan reviews and sends. The agents do everything up to that line.

An overture is both the opening piece of a performance and, literally, an approach or proposal made to someone. That is the job.

---

## 1. Why this exists (the data)

Dan's real 2026 booking log (156 rows) is unambiguous about what works:

- 24 total bookings. 22 came from warm contact, only 2 from cold.
- Cold "me to them" email: 128 attempts produced 2 bookings, about 1.6 percent.
- Warm contact (inbound, referral, repeat): 28 attempts produced 22 bookings, about 79 percent.

The current strategy is to comb venue event calendars (mostly Carnegie, especially Weill Recital Hall) and email anyone performing something that looks like a fit. The biggest single category of cold targets, the "International Competition Winners Recital" Weill rentals and agency-managed touring soloists, is a near total dead zone. Easy to find on a calendar, almost never converts.

So the goal is not volume. It is fit and qualification, plus removing the part Dan hates. The realistic target is 1 to 3 new repeat organizations per year plus a steady stream of one-off Weill recital shoots.

Two pain points drive everything:
1. Finding who to contact and their address is not hard, it is tedious. Dan gives up after 3 to 4 minutes per prospect because the payoff is not worth the drudgery. A machine has infinite patience for exactly this.
2. The niche means many groups budget little or nothing for photography. The rate is fixed and not high, so this is solved in the offer and the qualification, not by chasing fewer people.

---

## 2. Strategy

- **Rank, do not filter.** Everyone reachable still gets contacted (an email is cheap). The system spends its expensive effort (deep personalization, finding the named decision-maker, follow-ups) on the high-fit tier and gives the long shots a lighter touch. Same coverage, effort matched to odds.
- **One-offs rank equal to repeat organizations.** Dan is deliberately scaling back in spring and summer 2027 (he is trying to have a kid), so a one-off that does not depend on his future availability is genuinely valuable right now.
- **Land one shoot first, then leverage.** Cold outreach pitches a single shoot. The multi-concert and season angle, and any concession, stay in Dan's follow-up conversations, where he already handles them well. The cold email never mentions them.
- **Protect the inbox.** All sending goes through Dan's real Gmail, so deliverability rides on his actual reputation. Sends are throttled even when Dan approves a large batch at once.

---

## 3. Architecture

- **Mode: draft and approve.** Agents discover, rank, find the contact, and draft in Dan's voice, then queue. Dan reviews and sends. Nothing sends autonomously. This protects his voice and his sender reputation.
- **Platform: a custom app on Dan's own stack** (Next.js, Supabase, Vercel). Dan writes code, so he owns and maintains it. Hosting is effectively free on the tiers he is on.
- **Sending and replies: the Gmail API**, from dan@danwrightphotography.com (Google Workspace). Overture sends as genuine individual emails and detects replies (checked during the morning run) to auto-pause follow-ups. This requires authorizing that specific account; the account currently connected in tooling is Dan's Pennie work address, not the photography one.
- **Engine: Claude Code on Dan's Claude Max plan, not the paid API.** The agents run as a Claude Code workflow Dan launches, authenticated by his existing Max subscription, so there is no Anthropic API key and no per-use API cost. Web access uses Claude Code's own tools: web fetch and web search for most pages, and a headless browser (the free Playwright integration) for JavaScript-heavy, bot-protected venue calendars like Carnegie's. The Phase 0 probe confirmed this path works. No scraping subscription and no extra paid services; the only ongoing services are free-tier Supabase and Vercel for the dashboard.
- **Execution: Dan launches the run each morning; it is not unattended.** This is a deliberate trade Dan chose so the engine can ride his Max plan instead of a paid API. He opens the Overture command in the morning, it scouts, finds contacts, ranks, and drafts, and writes everything to Supabase; he then reviews and sends from the dashboard whenever he likes. Consequence, and a reversal of an earlier assumption: it runs only when Dan runs it, and his computer must be on while it works. It does not run overnight or while his machine is off. If full hands-off autonomy ever becomes worth a small monthly cost, the upgrade path is to switch the engine to the paid API on a cloud cron; nothing else in the system changes.

### The agents

These are not separately deployed services. They are stages of the single Claude Code workflow Dan runs each morning, in this order. The dashboard reads what they write.

- **Venue scout:** finds venues and calendars Dan does not already watch, so the funnel is not capped by his current mental list. (Phase 2.)
- **Event scout:** watches known venue calendars for upcoming performances. This is the one-off pipeline and the first agent built.
- **Org scout:** proactively hunts the high-fit profile (NYC-area choirs, music schools and academies, youth and community ensembles, small opera and theater companies), independent of any single performance. This is where the 79 percent lives. (Phase 2.)
- **Contact finder:** does the tedious dig and returns the right person, via a waterfall (below).
- **Ranker:** assigns the fit score, tier, and a one-line reason (below).
- **Drafter:** writes the email in Dan's voice (below).
- **Sequencer:** tracks state, schedules warm follow-ups, watches Gmail, and kills a sequence the instant someone replies.

---

## 4. Fit score (the ranker's brain)

Strongest signal to weakest:

1. **Prior warm relationship** (Dan's top weight): he has worked with them before.
2. **Self-produced (positive) vs agency or management routed (negative).** Agency-managed almost never converts.
3. **Profile match (positive):** choir, music school or academy, youth or community ensemble, small opera or theater company. **Competition-winner showcase rental (negative).**
4. **Likely uncovered (positive) vs likely already covered (negative):** a Weill recital or small self-produced show vs a Stern mainstage or a prestige touring act that travels with its own shooter.
5. **Discipline preference (Dan's standing rule):** music is the baseline to keep steady (Dan already gets music work). Every other discipline is preferred and gets a positive boost. **Dance ranks highest,** because Dan's dance portfolio is nearly empty (about four shoots) and he wants to grow it; opera and theater are also boosted above music.

**Geography is a gate, not a penalty.** Only performances at venues Dan can reasonably reach are surfaced at all. A touring or international group performing in NYC is fine, often good, because they want photos of that NYC performance. There is no local-versus-touring downvote. Reachability and travel are handled in section 8.

Use "performance," not "concert," everywhere. Dan shoots dance, theater, opera, choral, bands, and more, not just music.

---

## 5. Contact finder (waterfall)

For each prospect, in order, stopping at the first that works:
1. A named decision-maker (artistic director, marketing coordinator, development officer).
2. A verified generic inbox (info@, frontdesk@).
3. A web form or Instagram DM, flagged as a manual step Dan does in one click.

Every result carries a **confidence rating**: named decision-maker is high, generic inbox is medium, form or DM only is low.

---

## 6. The queue (the dashboard Dan lives in)

Dan chose to see everything with no daily cap and review whenever he wants. To make that safe and usable:

- **Sort by performance date ascending, fit score as the tiebreaker** on a shared date, so nothing time-sensitive slips past and the best fit rises first on a crowded day.
- **No cap on the queue, ad hoc review.** But sending is decoupled from reviewing: when Dan approves a batch, the system drips the actual sends at a safe rate behind the scenes, so Gmail never sees a burst. Dan can override the throttle for anything urgent.
- **Dismiss action** on every row, with a reason (date conflict, day does not work, not interested, already booked, duplicate). Dismissing a whole day blocks that date from future surfacing. On a multi-performance day, the siblings can be cleared in one move once Dan picks one. "Already booked" lets him clear, for example, a stack of DCINY dates he already has on contract.

Each row shows:
- Fit score and tier.
- Who and what: group, the specific performance, venue, date.
- Why it is a fit (one line from the ranker).
- The found contact and its confidence rating.
- A self-produced vs agency-managed badge.
- A performance discipline tag (dance, theater, opera, choral, band), filterable.
- Suggested outreach timing (how far out from the performance to send).
- A link to the group's website and a link to the source listing.
- A prior-history flag from the imported 156-row log ("booked them in 2025," "cold-emailed in Jan, no reply").
- The drafted email, editable inline, with approve, skip, and snooze.

Past or already-booked clients stay in the queue (ranked high via the prior-relationship weight) but can be marked "already booked" and dismissed.

---

## 7. The drafter

The `dan-wright-brand-voice` rules are ported into Overture as the drafter's system prompt (versioned in this repo). If Dan updates his voice, we update that prompt.

**Email anatomy** (from Dan's brand-voice email guide: direct, warm, concise, no throat-clearing, hold pricing positively, soft close):
1. Subject: specific and low-key, for example "Photographing [group]'s [performance] at [venue]."
2. Opener: a genuine, specific reason for reaching out, the group and work named correctly. No "I hope this email finds you well."
3. Body, 2 to 3 sentences: what Dan does (unobtrusive, no-flash documentary coverage), why it fits this performance, and a discipline-matched portfolio link.
4. Offer: handled positively. No multi-concert pitch, no promised freebies.
5. CTA: soft, aimed at the decision-maker, for example "let me know how that lands."

**A/B testing is a v1 requirement, not a nicety,** because the current cold approach is not converting. The drafter and sender assign and track email variants from day one. First things to test: stating the rate plainly vs linking the contract page, including a portfolio link vs not, and different openers. Deeper statistical analysis is filed as a later issue.

**Portfolio links** map a performance's discipline to the closest of the five site galleries: Music, Performing Arts, Bands, Comedy, Dance. There is no dedicated opera, theater, or choral gallery, so a choir or classical recital points to Music, a staged opera or play to Performing Arts, a dance company to Dance, and so on.

**Pricing in the email:** Dan charges a flat 250 dollars per hour plus tax (waived for tax-exempt clients with documentation), one hour minimum, charging only for time at the performance. The gallery is delivered within two weeks. He does not discount, with one deliberate exception: he will compromise on rate for dance shoots, to build his nearly-empty dance portfolio. The cold email does not lead with that flexibility, but dance prospects are flagged as rate-flexible so Dan can offer it in negotiation. Whether the email states the rate or links the contract page is the first A/B test. The drafter never promises freebies; concessions are Dan's to make later.

---

## 8. Follow-up, replies, geography

- **Follow-up:** a light, on-brand sequence, queued for approval like the first email. High-fit tier gets the first email plus a gentle nudge about 5 to 7 days later plus one final low-pressure value touch. Long shots get the first email plus at most one nudge. The moment anyone replies, all their follow-ups stop and it lands in Dan's inbox.
- **Reply detection:** the sequencer watches the Gmail thread and auto-pauses on any reply.
- **Geography and travel:** Dan is based at 97th and Columbus in Manhattan. Reachable means doable by public transit, with a short uber on the end acceptable. Subway preferred, bus and train fine. Manhattan is best. Convenience is energy-based, not purely time-based: a 90-minute trip to Brooklyn is less annoying than a 90-minute trip to Long Island. For v1, Claude estimates the route and trip hassle from the venue address and its knowledge of NYC transit, gates out the genuinely unreachable, and flags likely travel-fee trips. A maps or transit API is a later upgrade only if the estimates prove too rough.

---

## 9. Proposed data model (Supabase)

This follows from the decisions above and is open to revision during the build.

- **prospects:** group name, discipline, venue, performance date, source listing URL, website URL, self-produced vs agency, fit score, tier, fit-reason, geography or travel assessment, status (new, queued, approved, sent, replied, booked, lost, dismissed), dismiss reason, prior-history match.
- **contacts:** prospect id, name, role, email or form URL or instagram, contact-confidence, method.
- **drafts:** prospect id, subject, body, variant id, edited-by-Dan flag.
- **sends:** draft id, sent-at, gmail thread id, throttle batch.
- **events (replies and follow-ups):** prospect id, type, scheduled-at, sent-at, reply-detected-at.
- **history (imported):** the 156-row log, used for dedup and prior-relationship flagging.
- **blocked_dates:** dates Dan dismissed as "day does not work."
- **variants and outcomes:** for A/B testing and the later feedback loop.

---

## 10. Build phasing

- **Phase 0, spike: DONE.** Probed live during planning and came back GO (issue #7). A headless browser pulls clean structured events from Carnegie's bot-protected calendar, and web search finds contacts. This is now Claude Code's job, which is exactly what ran the probe.
- **Phase 1, MVP (the daily-usable core loop):** the Claude Code morning workflow Dan launches (event scout, then contact finder, then ranker, then drafter, A/B-ready), writing to Supabase; import the 156-row history for dedup and prior-relationship flags; the Next.js approval queue dashboard; Gmail send (throttled) and reply detection; a light follow-up sequencer that runs as part of the morning workflow. Event scout only. Needs the Supabase project and, at the send step, the Gmail authorization. No API key.
- **Phase 2:** org scout plus venue scout plus the Claude travel and routing estimate plus discipline gallery links.
- **Phase 3:** the six filed issues.

---

## 11. Deferred (filed as GitHub issues)

1. Repeat-client season radar (#1)
2. Post-shoot referral and testimonial loop (#2)
3. Availability-aware pitching, calendar-connected (#3)
4. Outcome-feedback loop to auto-tune the fit score (#4)
5. Subject-line and opener A/B testing, the deeper analysis layer (#5)
6. Pipeline analytics dashboard (#6)

---

## 12. Key risks

- **Calendar extraction: resolved.** Phase 0 proved the headless-browser path works on Carnegie's bot-protected calendar. The remaining soft spot is contact-finding accuracy for ambiguously-named groups, which the confidence rating and the form/DM manual fallback are designed to absorb.
- **The engine rides the Max plan.** Two consequences. First, it runs only when Dan launches it and only while his machine is on, not overnight or hands-off (his deliberate choice to avoid API cost). Second, if Anthropic restricts subscription use for this kind of automation, or Max usage limits bite on a heavy morning, the fallback is the paid API on a cloud cron, which also restores hands-off operation. The rest of the system is unaffected by that switch.
- **No send cap plus ad hoc review** could mean rubber-stamping a large pile. The send throttle protects deliverability; reading the drafts is on Dan.
- **The MVP fishes mostly in the lower-converting calendar pond.** The org scout (Phase 2) is where the 79 percent lives, so the value step-change comes when it lands.
