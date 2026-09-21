#!/bin/sh
set -e
here=$(dirname "$(readlink -f "$0")")
lib=/usr/lib/systemd/system
for f in "$here"/units/*; do systemctl stop "$(basename "$f")" 2>/dev/null || true; done
mount -o remount,rw /
trap 'mount -o remount,ro /' EXIT
for f in "$here"/units/*; do
  u=$(basename "$f")
  rm -f $lib/*.wants/$u $lib/$u
done
systemctl daemon-reload
