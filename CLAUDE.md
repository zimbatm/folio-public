# Working on Folio

Read `ARCHITECTURE.md` first: the parts, how an ask and a build flow, the trust
boundaries and the landmines. This file is how to work here. Keep both true:
when a change alters how things work, or you learn something the next build
needs, update them in the same change.

## Where you are

The builder runs in a clone of this repo at `origin/main`, on the host the
deployment chose. The service (`server/`) started you; it checks, tests,
commits and tags after you finish. Do not commit. The deployment's fixed rules
(appended to your prompt) say what that host has and lacks.

Tools missing on the host often come from Nix, for example
`nix shell nixpkgs#go -c go vet ./...`.

## What a change can touch

- `ui/` (not `ui/loader.qml`), `test/`, `application.qrc` and the docs (`CLAUDE.md`,
  `ARCHITECTURE.md`, `README.md`): a **version**. The service tests it, tags
  the next `vN`, and the user can install it on the tablet.
- Anything else (`server/`, `bridge/`, `tablet/`, `backend/`,
  `ui/loader.qml`, `build.sh`): a **proposal**. The service pushes it to a
  branch `proposal/<job>` for a person to review, merge and deploy. Say so in
  your paragraph for the user. For Go, run `go vet` and `go build` in that
  directory (with Go from Nix).

## Testing

- `test/run.sh`: the offscreen QtTest suite (Qt 6.11, stubs of the AppLoad
  modules in `test/net/`). It also compiles every file with the tablet's Qt
  6.10 `qmlcachegen` from the SDK (`FOLIO_SDK`, default `~/remarkable/sdk`); it prints
  `PASS: the tablet's Qt compiles every file`. Do not filter that line away.
  Make the whole run pass, and add a test when a change can be tested.
- `test/shots.sh`: renders each screen to `test/shots/*.png` at the tablet's
  size. Read the PNGs to check a layout. Add a shot when you add a screen.
- The offscreen tests cannot catch what crashes xochitl on the tablet (see
  the landmines in `ARCHITECTURE.md`). Never use `grabToImage`,
  `layer.enabled` or `ShaderEffect` in `ui/`.

## Lessons

- A `\uXXXX` escape typed through the Edit tool or a heredoc lands in the file
  as the literal character. A literal U+2028 or U+2029 ends a line for the QML
  lexer, `main.qml` stops loading, and every app test fails with `app.item`
  null. Use `String.fromCharCode(0x…)` or `\s`, and check with
  `LC_ALL=C grep -c $'\xe2\x80[\xa8\xa9]' ui/*`.
- To see why `main.qml` does not load, load it with `Qt.createComponent` in a
  small throwaway qmltestrunner test and print `errorString()`.
- A request that "replaces an earlier request that got cut off": the earlier
  attempt's files may still be in `test/tmp/code-good/v2/` (git-ignored).
  `test/run.sh` deletes `test/tmp`, so copy them out first. They may be older
  than `origin/main`: port the additions, keep what was added since.
- A `Row` lays out a child that becomes visible on the next frame: in a test,
  `wait(50)` before you click it.
- The tablet's fonts lack most symbols (no ✕, no arrows): draw them with a
  `Canvas` or `Rectangle`s.
- Qt 6.10 rejects `long` as a name. The compile check catches it; the tests do
  not.
- A new `ui/*.js` file that `main.qml` imports goes into `application.qrc`
  too: that list is the copy built into the app, the fallback. `test/run.sh`
  checks it.

## Style

- Text on the page and in docs: short sentences, simple words.
- Code comments only where the code cannot say why.
