# Folio's tablet setup

Runs as root on the tablet, from `/home/root/folio`. Copy this directory there
and run `install.sh`; run it again after each OS update, since an update
replaces the rootfs.

- `units/folio-xovi.service`, `xovi-boot.sh`: xovi at boot (below).
- `units/folio-notes-push.*`, `notes-push.sh`: the notes mirror (below).
- `/home/root/.config/folio/folio.env` (not here), read by the app and the
  notes push:

      ANTHROPIC_BASE_URL=http://127.0.0.1:18081   # the bridge
      ANTHROPIC_API_KEY=…                         # the bridge's token
      FOLIO_SERVER_URL=http://127.0.0.1:18082     # the server (this is the default)
      FOLIO_SERVER_TOKEN=…                        # the server's token

How the tablet reaches the bridge and the server is up to you: an SSH or
WireGuard tunnel to the host that runs them, or the local network. Both check
a token; neither encrypts, so outside a trusted network use a tunnel. The tablet
is a weak device (developer-mode root over USB), so give it a path to those
two services and nothing else.

## xovi at boot

`/home/root/xovi` holds xovi, qt-resource-rebuilder and AppLoad. Their
drop-ins are tmpfs, so every boot is stock. `folio-xovi.service` runs
`xovi-boot.sh`: 60 s after a stock boot it starts xovi once and watches
xochitl for 5 minutes. A crash in that window puts it back on stock.

- A crash loop cannot be caught: xochitl's `OnFailure=emergency.target` runs
  `rm-emergency.sh`, which reboots (and right after an OS update also goes
  back to the previous OS partition). A drop-in cannot remove it. So the
  script marks each try in `~/.local/state/folio-xovi/pending` and clears it
  only after the 5 minutes; while it is there, boots stay stock.
- It also stays stock while `swu_applied` is set (an unconfirmed OS update),
  and when the hashtab's OS version is not `/etc/os-release`'s: after an OS
  update, run `/home/root/xovi/rebuild_hashtable`.
- Kill switch: `touch /home/root/folio/no-xovi`.
- Each boot costs two unlocks: stock, then xovi restarts xochitl.

## Notes mirror

`folio-notes-push.timer` runs `notes-push.sh` every 10 minutes (and 3
minutes after boot): the xochitl files changed since the last good push, as
a tar sent gzipped and in base64 (busybox wget cuts a posted file at the
first NUL), then the full list so deletions carry over.

