# Gmail reply search fixtures (#2713)

What the mailbox search parses: a `users.messages.list` response (paginated) and a
`users.messages.get?format=metadata` response.

These are `messages.list` and `messages.get` responses, NOT `threads.get` responses. Every other
Gmail read in this app goes through `threads.get`, which has a different shape (a `messages` array of
whole message objects, no `nextPageToken`, no `resultSizeEstimate`). Testing the search against a
thread response would only confirm an assumption about an interface nobody read (L52), so the search
gets its own fixtures in the shape it actually receives.

## Provenance, stated plainly

The SHAPE is taken from Google's published reference, read in the same change that stubbed it
(fetched 2026-08-14):

- <https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list>
- <https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/get>

Every field present here is a field that reference documents, and every field the parser reads is
present here: `messages[].id`, `messages[].threadId`, `nextPageToken`, `resultSizeEstimate`, and on a
metadata get `id`, `threadId`, `labelIds`, `snippet`, `historyId`, `internalDate` (a string holding
milliseconds since the Unix epoch), `sizeEstimate` and `payload.headers[]` as `{name, value}` pairs.

The CONTENT is written for this fixture rather than captured from Dan's mailbox. That is a deliberate
gap and it is named rather than papered over: a real capture of the window this search reads is Dan's
personal inbound correspondence, and committing it here would put third parties' names, addresses and
message snippets into the repository (L19). What a capture would have proved beyond the published
reference is that Gmail returns no field the reference omits, which the parser is written not to
depend on: it reads named fields and ignores everything else, and
`GmailReplySearchTests.aResponseCarryingUnknownFieldsStillParses` holds it to that.

## Files

| File | What it is |
| --- | --- |
| `messages-list-page1.json` | A first page, carrying a `nextPageToken` |
| `messages-list-page2.json` | The final page, carrying no token |
| `message-metadata.json` | One `format=metadata` message with `From`, `Subject` and `Date` |
