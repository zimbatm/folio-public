# Folio: how it is built

Folio is an assistant on a reMarkable Paper Pro Move. You write with the pen;
the model answers on the page. It can change itself: it writes a change
request, the builder makes a new version, and you install it.

This file is the one description of the whole system. The builder reads it
before each build, and the assistant gets a summary of it in each ask. When a
change touches the design, update this file in the same commit.

## The parts

| Part | Where it runs | Code | What it does |
|---|---|---|---|
| **Folio app** | the tablet, inside xochitl (AppLoad) | `ui/`, `backend/`, `build.sh` | the page, the asks, Install |
| **Folio server** | a server host | `server/` | builds versions, serves them, mirrors and searches the notebooks, keeps the job logs |
| **Folio bridge** | a server host | `bridge/` | the model: the Messages API on top of `claude -p` |
| **Tablet setup** | the tablet, as root | `tablet/` | xovi at boot, the notes push |

The server and the bridge are Go programs with no dependencies.
`nix/module.nix` (`nixosModules.default` in `flake.nix`) runs both as one
unprivileged user on one Claude login. How the tablet reaches them (a tunnel,
a VPN, the local network) is the deployment's choice; the app finds them
through `/home/root/.config/folio/folio.env` (see `tablet/README.md`).

    tablet: Folio app (QML) ──► ANTHROPIC_BASE_URL ──► folio-bridge ──► claude -p (no tools)
              ├───────────────► FOLIO_SERVER_URL ───► folio-server
              └── backend/entry (native, root): the pen's eraser end, and Folio's lines in the xochitl journal
    tablet: notes-push.sh (a timer, every 10 min) ─► folio-server: the notes mirror

## An ask

1. The app sends a job to the bridge: `POST /v1/jobs` with the page (text,
   the page map, images of the new ink), the conversation, Folio's notes, the
   recent builds, and a self-report (the version, the model, Folio's recent
   log lines). It polls `GET /v1/jobs/{id}`.
2. The bridge runs `claude -p` with no tools. The client's tools (`reply`,
   `web_search`, `fetch_url`, `weather`, `screenshot`) become one structured
   output: the model picks one call. The tablet runs web calls itself and asks
   again with the results, at most 5 calls a reply.
3. The app places the reply. `reply` can also carry notes (Folio's memory),
   an `app_change` (a change request, shown as a card) and a `notes_query` (a
   search in the notebooks, which the server answers).
4. Jobs are files in the bridge's `--jobs-dir` for 1 hour, so a bridge
   restart runs a cut-off ask again. The app retries a failed connection 4
   times (a tunnel needs a few seconds after the tablet wakes).

## A change to Folio

1. You tap **Build it** on a change card. The app sends the request to the
   server (`POST /v1/improve`). One build runs at a time; a second is refused.
2. The server starts the builder: `claude -p` with full tools, in a clone of
   this repo (`--repo`) at `origin/main`. It reads `CLAUDE.md` and this file,
   then works; each tool call goes to the job's log (**More › Activity**).
3. The server runs `test/run.sh`, commits, rebases on `origin/main`, tags the
   next `vN` and pushes. A conflict fails the job cleanly.
4. The app shows **Install vN**. Install writes the version's `ui/` files into
   the next slot (`code/s0`…`s7`) and `code/current`. Reopen Folio to run it.
   The loader falls back to the copy built into the app when a version fails
   to load.

The builder's limits, in order of strength:
- Its fixed rules come from the deployment (`--core`, a file outside this
  repo), so no commit here can remove them: no `grabToImage`, layers or
  shaders; work only in the repo; run the tests.
- It runs with `--setting-sources project`: hooks and settings in the user's
  `~/.claude` do not load. Its memory there does.
- A change outside the app and its docs (`server/`, `bridge/`, `tablet/`,
  `backend/`, the loader, `build.sh`) is not a version: the server pushes it
  to a branch `proposal/<job>` for a person to review, merge and deploy.
- Versions are text (QML/JS). The loader, the icon, the manifest and the
  native backend ship only with `./build.sh --install`, which needs the SDK and
  a person.

## The notes mirror

`tablet/notes-push.sh` sends the xochitl files changed since the last good
push (gzip + base64: busybox wget cuts a posted file at the first NUL), then
the full list, so deletions carry over. The server renders pages (`rmc` for
v6, its own renderer for v3/v5, then `rsvg-convert`) and keeps `INDEX.md`. A
`notes_query` runs `claude -p` with Read, Glob and Grep over the mirror.

## Trust

- The input is untrusted: anything written on the page, and any web page.
- Run the server and bridge on a host that holds nothing else of yours: the
  builder has full tools there. Give it one write deploy key for this repo
  and the Claude login, nothing more.
- Both services check a token on every request (`x-api-key`): the bridge's
  lets a caller ask, the server's lets it build, read the job logs and the
  notes. The server does not start without one. The tokens do not encrypt:
  outside a trusted network, put a tunnel or TLS in front, and let only the
  tablet reach the two services.
- The tablet is a weak device (developer-mode root over USB): give it a path
  to those two services and nothing else.
- The builder writes code that ships to the tablet. Your tap on Install is the
  gate for app versions; merging a proposal and deploying it is the gate for
  everything else. If you deploy the server from this repo, move your pin to
  a new commit only after you read the diff.

## Landmines

- xochitl renders in software: `grabToImage`, `layer.enabled` and
  `ShaderEffect` crash it. Nine crashes in a row and the tablet reboots.
- The tablet's Qt is 6.10; the tests use 6.11. `test/run.sh` also compiles
  every file with the SDK's 6.10 `qmlcachegen` (`FOLIO_SDK`, default
  `~/remarkable/sdk`). Qt 6.10 rejects `long` as a name.
- xochitl keeps each QML file it parsed, or failed to parse, by its path
  until it restarts: an install never reuses a path it may have loaded.
- A network callback after Folio closes crashes xochitl: make XHRs with
  `Net.xhr()`; `unloading()` aborts them.
- Restarting the server or the bridge cuts a build (it is lost) or an ask (it
  starts again). Check for running jobs first.
- QML XHR cannot write binary files or create directories.
- AppLoad starts the native backend once and keeps it across Folio's close
  and open, until xochitl restarts. After `build.sh --install`, stop the old
  `backend/entry` (AppLoad then closes Folio cleanly) and open Folio again.

## Names

Some internal names still say `claude`: the AppLoad app ID and folder
(`exthome/appload/claude`), its socket (`/tmp/claude.sock`) and the data
folder (`~/.local/share/claude-app/`). Renaming them means moving live data
while Folio is closed and rebuilding the loader.
