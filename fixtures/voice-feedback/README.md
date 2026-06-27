# `overture-voice-feedback.json` fixture

The voice-learning handoff (#241 / #119). The **app writes** it (when a Prep run launches) and the
**Prep drafter workflow reads** it (#242) to learn how Dan revises drafts. One-sided contract: the
reader is a Claude Code workflow, not code, so this fixture plus the prep runbook is its spec.

`v1.json` pins the wire shape `VoiceFeedbackBuilder.encode` emits: a versioned envelope plus an array
of high-signal pairs (an AI draft Dan substantively edited and sent, where the sent copy genuinely
differs from the AI original), newest first, capped at 20. Asserted by `VoiceFeedbackContractTests`.
When the shape changes, update this fixture and the test in the same change.
