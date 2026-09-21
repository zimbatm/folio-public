#!/bin/bash
# Starts xovi (AppLoad, the Claude app) once the tablet is up on stock
# xochitl, from folio-xovi.service at boot.
#
# xovi's drop-ins are tmpfs, so every boot is stock. When xochitl fails for
# good (StartLimitBurst=4 in 10 min), its OnFailure= starts emergency.target,
# whose rm-emergency.sh reboots, and right after an OS update also switches
# back to the previous OS partition. A drop-in cannot remove that OnFailure=
# (a dependency list only grows). So the dangers are a boot loop and undoing
# an update, and the answers are: try once per boot, mark the try until it
# settles, stay stock after a try that did not, and never try on the first
# boot of an update or with a hashtab built for another OS version.
set -u
xovi=/home/root/xovi
hashtab=$xovi/exthome/qt-resource-rebuilder/hashtab
state=/home/root/.local/state/folio-xovi
pending=$state/pending
settle_checks=60 # x 5 s

log() { echo "folio-xovi: $*"; }

restarts() { systemctl show -p NRestarts --value xochitl.service; }

to_stock() {
  systemctl reset-failed xochitl.service
  "$xovi/stock"
  systemctl start xochitl.service
}

mkdir -p "$state"

if [ -e "$pending" ]; then
  log "an earlier xovi start did not settle: staying stock (remove $pending to allow it)"
  exit 0
fi

if [ "$(cat /sys/devices/platform/lpgpr/swu_applied 2>/dev/null)" != 0 ]; then
  log "an OS update is not confirmed yet: staying stock"
  exit 0
fi

# shellcheck disable=SC1091
os=$(. /etc/os-release && echo "${IMG_VERSION:-}")
built=$(dd if="$hashtab" bs=256 count=1 2>/dev/null | tr -c '0-9.' '\n' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$')
if [ -z "$os" ] || [ "$os" != "$built" ]; then
  log "the hashtab is for ${built:-nothing}, the OS is ${os:-unknown}: staying stock (run $xovi/rebuild_hashtable)"
  exit 0
fi

sleep 60
if ! systemctl is-active -q xochitl.service; then
  log "xochitl is not active on stock: not starting xovi"
  exit 0
fi

touch "$pending"
sync
"$xovi/start"
sleep 5

# xovi/start restarts xochitl by hand, which zeroes NRestarts: any automatic
# restart from here on is a crash
pid=$(systemctl show -p MainPID --value xochitl.service)
if [ "$pid" = 0 ] || [ "$(restarts)" != 0 ] ||
  ! tr '\0' '\n' <"/proc/$pid/environ" | grep -q "^LD_PRELOAD=$xovi/xovi.so"; then
  log "xochitl did not come up with xovi: back to stock"
  to_stock
  exit 0
fi

for _ in $(seq "$settle_checks"); do
  sleep 5
  if ! systemctl is-active -q xochitl.service ||
    [ "$(systemctl show -p MainPID --value xochitl.service)" != "$pid" ] ||
    [ "$(restarts)" != 0 ]; then
    log "xochitl restarted under xovi: back to stock"
    to_stock
    exit 0
  fi
done

rm -f "$pending"
sync
log "xovi is up and settled"
