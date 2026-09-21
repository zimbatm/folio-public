#!/usr/bin/env bash
# build.sh [--install]: pack the app into out/ and, with --install, copy it to the tablet
set -euo pipefail
cd "$(dirname "$0")"
sdk=${FOLIO_SDK:-$HOME/remarkable/sdk}
# an ssh host for the tablet (root, key-only)
tablet=${FOLIO_TABLET:-remarkable}
rcc=$sdk/sysroots/x86_64-codexsdk-linux/usr/libexec/rcc
rm -rf out && mkdir -p out/backend
cp manifest.json icon.png out/
"$rcc" --binary -o out/resources.rcc application.qrc
# the backend is native, so only this build ships it (the server's versions are text)
(
  set +u
  # shellcheck disable=SC1091
  . "$sdk"/environment-setup-cortexa55-remarkable-linux
  $CC -O2 -Wall -o out/backend/entry backend/eraser.c
)
if [[ ${1:-} == --install ]]; then
  # an open app has resources.rcc mapped: overwriting it in place crashes
  # xochitl, so upload beside it and rename over it
  d=/home/root/xovi/exthome/appload/claude
  # QML cannot create directories: the update slots (see nextSlot in ui/main.qml)
  c=/home/root/.local/share/claude-app/code
  ssh "$tablet" "mkdir -p $d/.new $d/backend $c/a $c/b && for i in 0 1 2 3 4 5 6 7; do mkdir -p $c/s\$i && echo s\$i > $c/s\$i/SLOT; done"
  scp -q out/manifest.json out/icon.png out/resources.rcc "$tablet:$d/.new/"
  scp -q out/backend/entry "$tablet:$d/.new/entry"
  ssh "$tablet" "cd $d && mv .new/entry backend/entry && for f in .new/*; do mv \"\$f\" .; done && rmdir .new"
fi
