# Overture

Outreach system for Dan Wright Photography. It finds performing arts organizations and performances worth pitching, finds the right person to contact, drafts an email in Dan's voice, and queues it for Dan to approve and send. Draft and approve: the agents do everything up to the send line.

See [PLAN.md](./PLAN.md) for the full plan, decisions, and build phasing.

## Status

Planning complete and de-risked. Nothing built yet. Phase 0 (feasibility) is proven (issue #7): a headless browser extracts Carnegie's bot-protected calendar and web search finds contacts. Next is the Phase 1 build, once the Supabase project exists.

## How it runs

Dan launches a Claude Code workflow each morning on his Claude Max plan. It scouts venue calendars, finds contacts, ranks, and drafts emails in his voice, writing everything to Supabase. Dan reviews the queue in a Next.js dashboard and sends. It runs only when Dan runs it (his choice, to avoid a paid API); his machine must be on while it works. Hands-off overnight operation is a later upgrade (switch the engine to the paid API on a cloud cron).

## Stack (planned)

Engine: Claude Code on the Max plan (no API key, no per-use cost). Dashboard: Next.js on Vercel. Data: Supabase. Sending and reply detection: the Gmail API from dan@danwrightphotography.com. Web access: Claude Code's web fetch and web search, plus the Playwright headless browser for JavaScript-heavy calendar pages. Only free-tier services beyond the existing Max plan.

## Open enhancements

Tracked as GitHub issues, labeled `v2`.
