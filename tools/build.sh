#!/usr/bin/env bash
# build.sh [--install]: builds the tablet's debug tools (rmin, fbgrab, evread)
# with the SDK and, with --install, copies them and the scripts' tablet side
# to /home/root/folio/tools on the tablet
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
sdk=${FOLIO_SDK:-$HOME/remarkable/sdk}
tablet=${FOLIO_TABLET:-remarkable}
set +u
# shellcheck disable=SC1091
. "$sdk"/environment-setup-cortexa55-remarkable-linux
set -u
mkdir -p out
for t in rmin fbgrab evread; do $CC -O2 -Wall -o out/$t $t.c; done
if [[ ${1:-} == --install ]]; then
  ssh "$tablet" mkdir -p /home/root/folio/tools
  scp -q out/rmin out/fbgrab out/evread "$tablet:/home/root/folio/tools/"
fi
