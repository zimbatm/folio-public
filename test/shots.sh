#!/usr/bin/env bash
# shots.sh: renders each screen to test/shots/*.png (see shots.qml)
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
mkdir -p "$here/shots"
FOLIO_SDK=/nonexistent QML_TEST_FILE="$here/shots.qml" "$here/run.sh" "$@"
