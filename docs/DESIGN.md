# Folio: paper first

The design for the next versions (2026-09-21). `ARCHITECTURE.md` describes
what runs today; this file describes where the app goes, and why.

Status: paper mode is in v28 (the interactions) and v29 (what the agent
gets); reading pages and the `folio` command in v30; PDFs, pictures and the
Claude Code skill (`skills/folio/`) in v31. Done is a button in the
title row, not a card at the end: it stays in reach while you read.

## Why

Folio today reacts to almost everything: it sends after a 4-second pause,
turns handwriting into type, and places answers and status lines while you
write. That is tiring. A notebook should be quiet until you want the agent,
and it should help you step away from the computer.

## Principles

1. **The page is paper.** Nothing is sent and nothing on the page changes
   until you ask.
2. **You say when, and about what:** a loop around one part, or the whole
   page.
3. **The answer goes where you asked:** next to the loop.
4. **The agent knows the page.** It reads each piece of ink once, keeps what
   it read, and each ask tells it what changed since its last answer.
5. **Reading is its own place.** Send something from the computer, read it on
   the tablet with a pen, and get a digest of your notes back.

## Interactions

| You do | The request | The answer |
|---|---|---|
| **Ask**, then draw a loop | what the loop holds (a question, or a question and what it is about) | next to the loop |
| **Ask** twice (the second tap is **Whole page**) | everything on the page | where it fits, or at the end |
| **Done** at the end of a reading page | the document and all your marks on it | a digest |

A loop around something with no question means "tell me about this".

These do not ask anything: correcting a typed word (tap it), following a link
(tap it), **Build it** and **Install** on a change card.

### The Ask button

- **At rest:** "Ask". Your pen writes ink.
- **Armed** (after one tap): the label reads "Whole page", and a line under
  the toolbar says "Circle what you mean, or tap Whole page". The next stroke
  is a loop, drawn dashed so it looks different from your own circles.
- **Sent:** when the loop closes, or on the second tap. The label shows "…"
  until the answer is on the page.
- **Cancel:** tap anywhere else, or Undo.

Ask must be tapped first because you also circle things in your own notes. A
loop only becomes a request when you said so.

### What goes away

- Sending after a pause, the check mark and the double tap (**More › Send
  with**): they are the reacting to everything.
- The Lasso button: Ask is the lasso now.
- Type replacing your ink while you write. Your ink stays ink.
  **More › Show › Your text: typed** remains for when you want it.
- Answers nobody asked for. The prompt tells the agent to answer only the
  request: no change ideas, no remarks on earlier ink, unless you ask. It may
  still update its own notes, silently.

## Screens

The toolbar: **Ask**, **Undo**, **Erase**, **More**, and **✕** apart on the
right.

Under it, a **title row**: the page you are on ("Conversation", or the title
of a reading), and "1 to read" when something waits. Tap it for **Pages**.

**Pages** lists the conversation and each reading, newest first, with its
state: to read, reading, done (with its digest). Back and Close, as in
Activity.

    ┌ Ask   Undo   Erase   More          ✕ ┐     ┌ Pages ──────────────── Close ┐
    │ Conversation ▾            1 to read  │     │ Conversation                 │
    │                                      │     │ ● spec.md          to read   │
    │  (your ink, the agent's answers)     │     │   PR #41 diff      done ✓    │
    │                                      │     │   rollout memo     reading   │
    └──────────────────────────────────────┘     └──────────────────────────────┘

## Reading pages

1. **Send** from the computer or a Claude Code session:
   `folio send spec.md` (a file, a diff, a URL, or text on stdin).
2. The tablet shows "1 to read" in the title row. Open it from **Pages**.
3. **Read and write.** The toolbar is hidden (the tab at the top brings it
   back). A tap at the top or bottom edge turns one screen: scrolling is slow
   on e-ink. The text is dark grey, so your ink stands out. Nothing is sent.
4. **Ask** works here too: a loop around a passage and a question gets an
   answer in the margin.
5. After the document, blank paper for your own notes. **Done** is in the title
   row.
6. **Done** sends the document and your marks. The agent writes a **digest**:
   a short summary of what you thought; your decisions, questions and to-dos
   as lists; and each mark with the passage it covers and your note.
7. The digest shows on the page, and waits on the computer: `folio notes`
   prints new digests, and `folio send --wait` returns it to the session that
   sent the document, which can then act on it.

## What the agent gets

Every ask:
- **Since your last answer:** the new ink and where it is, what you erased,
  and which of its items you marked or crossed out.
- **The page map of the whole page** (not the 40 regions nearest the new ink,
  as today): every region with its text. The agent reads each piece of ink
  once; the text is kept even when the ink stays ink on screen.
- **The conversation:** the recent turns as text, and a short summary of the
  older ones that the agent writes and keeps, so a long page does not make
  each ask longer.

Then, by request:
- **A loop:** an image of what the loop holds, in full detail, and the screen
  around it.
- **Whole page:** small images of any ink it has not read yet.
- **Done:** the document's text, and each mark with the text under it (as web
  pages do today: "the new ink is over this text").

## Server and command

- The server gets an inbox (`POST /v1/inbox`, `GET /v1/inbox`) and digests
  (`GET /v1/digests`), behind its token. For a PDF it renders page images and
  extracts the text of each page.
- `folio`: a small Go command in the repo, with `send`, `notes` and `send
  --wait`, reading `FOLIO_SERVER_URL` and `FOLIO_SERVER_TOKEN`.
- A document and a digest are untrusted text: `folio` prints a digest as
  quoted data, so a session does not take it as instructions.

## Build order

1. **Paper mode:** the Ask states, the loop as the request, Whole page, answers
   next to the loop, the removals above, and the new context (since your last
   answer, the whole page map, read once, summaries).
2. **Reading pages:** Pages and the title row, reading mode, Done and
   digests, the inbox and `folio send/notes`. Text, Markdown, code and diffs.
3. **More kinds:** PDF and images, URLs, a Claude Code skill.

## Open

- A reading page after Done: stays in **Pages** as "done" (assumed), or goes
  to an archive.
- **Whole page** means everything on the page, including what is off screen
  (assumed); a loop around what you see covers "this screen".
