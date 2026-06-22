# Overture

Outreach system for Dan Wright Photography. It finds performing arts organizations and performances worth pitching, finds the right person to contact, drafts an email in Dan's voice, and queues it for Dan to approve and send. Draft and approve: the agents do everything up to the send line.

See [PLAN.md](./PLAN.md) for the full plan, decisions, and build phasing.

## Status

Planning. Nothing built yet. Next step is the Phase 0 spike: prove the event scout can pull structured performances from Carnegie's live calendar and the contact finder can get emails off artist pages, all under the Claude-API-only constraint.

## Stack (planned)

Next.js, Supabase, Vercel. Sends and reply detection via the Gmail API from dan@danwrightphotography.com. Web access via Claude's built-in web search and web fetch, plus self-hosted Playwright for JavaScript-heavy calendar pages. No paid services beyond the Claude API.

## Open enhancements

Tracked as GitHub issues, labeled `v2`.
