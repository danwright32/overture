# Overture

Outreach system for Dan Wright Photography. It finds performing arts organizations and performances worth pitching, finds the right person to contact, drafts an email in Dan's voice, and queues it for Dan to approve and send. Draft and approve: the agents do everything up to the send line.

See [PLAN.md](./PLAN.md) for the original plan and rationale (its note at the top covers what shipped differently), and [CONTEXT.md](./CONTEXT.md) for the current domain glossary.

## Status

Shipped and in daily use.

## How it runs

Overture is a native macOS app (`mac/`) that Dan runs as a menu bar app on his own machine, backed by a TypeScript scout engine (`src/lib/`, `scripts/`) that finds and ranks performances. Dan triggers Scout and Prep from the app; each runs as a background job that calls Claude Code on his Max plan. Scout watches venue calendars and ranks candidates; Prep finds contacts and drafts emails, only for the candidates Dan kept. Results hand off to the app through a JSON file, which the app ingests into its local SwiftData store, the same store Dan reviews, approves, and sends from.

Sending and reply detection go through the Gmail API. A reply does not auto-pause anything: Dan reads it in Gmail first, Overture surfaces the reply and drafts an AI-suggested response, and Dan marks the outcome by hand. A performance can have more than one recipient (an act and a presenter, for example), each emailed and tracked separately; a performance's overall status (new, active, lost, or booked) is derived from its recipients' individual outcomes.

It runs only when Dan triggers it (his choice, to avoid a paid API); his machine must be on while it works. Hands-off overnight operation would require switching the engine to the paid API on a cloud cron, which is not planned.

## Stack (shipped)

Engine: Claude Code on the Max plan (no API key, no per-use cost), TypeScript (`src/lib/`, `scripts/`), tested with `vitest`. App: a native SwiftUI app with a local SwiftData store, generated with `xcodegen` from `mac/project.yml`. Handoff: fixed-shape JSON files between the engine and the app (see `docs/contracts.md`). Sending and reply detection: the Gmail API. Web access for the engine: Claude Code's web fetch and web search, plus a headless browser for JavaScript-heavy calendar pages.

## Open enhancements

Tracked as GitHub issues, labeled `v2`.
