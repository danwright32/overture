// The TypeScript twin of `DraftGreeting.opensWithAGreeting` (#2545, #3555): does a drafted body OPEN with
// a greeting?
//
// Overture holds a send whose body does not (`Recipient.draftIsMissingGreeting`, `isBlockedByGreeting`),
// because nothing composes a greeting above the body any more. `prepEval` scores what a Prep run produced
// with this, so a run whose drafts the app would refuse cannot score as compliant.
//
// Before #3555 the eval carried its own looser spelling of the rule (any body whose first word was an
// opener), which accepted "Hello Dolly opens at the Palace in March." as a greeting while the app holds it,
// and refused Dan's own shape ("Marcus, hello again,") while the app accepts it. Two implementations of one
// judgment drift the moment either is touched, so both are tested against ONE committed corpus,
// `fixtures/draft-greeting/cases.json` (L26), exactly as the ask and date rules are. The SWIFT side is the
// declared source of truth, because it is the gate a send meets; the patterns below are copied from
// `mac/Overture/Domain/DraftGreeting.swift` and must change with it.

const OPENERS = "hi|hello|hey|dear|good morning|good afternoon|good evening";

// The `Attn: <name>, <role>` block a shared-inbox pitch opens with (#610), and the blank line under it.
const ATTN_BLOCK = /^\s*Attn:[^\n]*\n\s*/i;

// An opener word, at most 40 characters of anything but a comma, bang or line break, then one of those.
const GREETING = new RegExp(`^\\s*(${OPENERS})\\b[^,!\\n]{0,40}([,!]|\\n)`, "i");

// A greeting that does NOT begin with an opener word, recognised by shape: a short first line ending in a
// comma or bang, carrying no sentence-ending punctuation, followed by a line break or the end.
const GREETING_SHAPE = /^[^\n.?!]{1,40}[,!]\s*(\n|$)/i;

export function opensWithAGreeting(body: string | undefined | null): boolean {
  if (!body) return false;
  const text = body.replace(ATTN_BLOCK, "");
  return GREETING.test(text) || GREETING_SHAPE.test(text);
}
