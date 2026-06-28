# `overture-voice-feedback.json` fixture

The voice-learning handoff (#241 / #119). The **app writes** it (when a Prep run launches) and the
**Prep drafter workflow reads** it (#242) to learn how Dan revises drafts. One-sided contract: the
reader is a Claude Code workflow, not code, so this fixture plus the prep runbook is its spec.

`v1.json` pins the wire shape `VoiceFeedbackBuilder.encode` emits: a versioned envelope plus an array
of high-signal pairs (an AI draft Dan substantively edited and sent, where the sent copy genuinely
differs from the AI original), newest first, capped at 20. It is kept byte-identical as the
backward-decode proof. `v2.json` (#392) adds an optional `outcomeRecipientId` to each pair,
attributing the outcome to the recipient who earned it (the booked one, else the first replier). The
body is shared across a show's recipients, so there is still exactly ONE pair per show; the field only
credits the win. Both are asserted by `VoiceFeedbackContractTests`. When the shape changes, update the
fixtures and the test in the same change.
