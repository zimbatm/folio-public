#!/usr/bin/env bash
# run.sh: offscreen QtTest of the app, with stubs of AppLoad's QML modules
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
decl=$(nix build --no-link --print-out-paths nixpkgs#qt6.qtdeclarative)
base=$(nix build --no-link --print-out-paths nixpkgs#qt6.qtbase)
svg=$(nix build --no-link --print-out-paths nixpkgs#qt6.qtsvg)
export QT_QPA_PLATFORM=offscreen
export QML_IMPORT_PATH=$here:$decl/lib/qt-6/qml
export QT_PLUGIN_PATH=$base/lib/qt-6/plugins:$svg/lib/qt-6/plugins
export FONTCONFIG_FILE=$(nix build --no-link --print-out-paths nixpkgs#fontconfig.out)/etc/fonts/fonts.conf
export QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1
# the tablet's Qt (6.10) rejects code that the test Qt accepts, e.g. `long`
# as a name; with the SDK at hand, compile every file with its qmlcachegen
sdk=${FOLIO_SDK:-$HOME/remarkable/sdk}/sysroots/x86_64-codexsdk-linux
if [ -x "$sdk/usr/libexec/qmlcachegen" ]; then
  out=$(mktemp -d)
  for f in "$here"/../ui/*.qml "$here"/../ui/*.js; do
    # stderr only on failure: the SDK's glibc has no UTF-8 locale and warns each time
    "$sdk/lib/ld-linux-x86-64.so.2" --library-path "$sdk/usr/lib:$sdk/lib" \
      "$sdk/usr/libexec/qmlcachegen" --only-bytecode -o "$out/$(basename "$f").cache" "$f" 2>"$out/err" ||
      { grep -v -i locale "$out/err"; echo "FAIL: the tablet's Qt cannot compile $(basename "$f")"; exit 1; }
  done
  rm -rf "$out"
  echo "PASS: the tablet's Qt compiles every file"
else
  echo "SKIP: no SDK at $sdk, so the tablet's Qt did not check the files"
fi
# the copy built into the app is application.qrc: a ui/ file the list lacks
# makes that copy fail to load, and it is the fallback
for f in "$here"/../ui/*.qml "$here"/../ui/*.js; do
  f=$(basename "$f")
  grep -q "<file>ui/$f</file>" "$here/../application.qrc" || { echo "FAIL: application.qrc lacks ui/$f"; exit 1; }
done
echo "PASS: application.qrc lists every file in ui/"
rm -rf "$here/tmp"
mkdir -p "$here/tmp/code-none" "$here/tmp/code-good/v2" "$here/tmp/code-bad/v3"
trap 'rm -rf "$here/tmp"' EXIT
for f in "$here"/../ui/*.qml "$here"/../ui/*.js; do [ "$(basename "$f")" = loader.qml ] || cp "$f" "$here/tmp/code-good/v2/"; done
echo v2 >"$here/tmp/code-good/current"
echo "v7" >"$here/tmp/code-good/v2/VERSION"
printf 'import QtQuick\nItem { this is not qml\n' >"$here/tmp/code-bad/v3/main.qml"
for s in s0 s1; do mkdir -p "$here/tmp/data/code/$s" && echo $s >"$here/tmp/data/code/$s/SLOT"; done
echo v3 >"$here/tmp/code-bad/current"
"$decl/bin/qmltestrunner" -input "${QML_TEST_FILE:-$here/tst_app.qml}" "$@"
