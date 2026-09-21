#!/bin/sh
# Installs Folio's units on the tablet's rootfs: xovi at boot and the notes
# push. An OS update replaces the rootfs, so run this again after each update.
# How the tablet reaches the Folio server and bridge (a tunnel, a VPN, the
# local network) is up to you: see README.md.
set -e
here=$(dirname "$(readlink -f "$0")")
lib=/usr/lib/systemd/system
mount -o remount,rw /
trap 'mount -o remount,ro /' EXIT
for f in "$here"/units/*; do
  u=$(basename "$f")
  cp "$f" $lib/$u
  target=$(sed -n 's/^WantedBy=//p' "$f")
  if [ -n "$target" ]; then
    mkdir -p $lib/$target.wants
    ln -sf ../$u $lib/$target.wants/$u
  fi
done
systemctl daemon-reload
systemctl restart folio-notes-push.timer
systemctl --no-pager status folio-notes-push.timer | grep -E "●|Active:"
