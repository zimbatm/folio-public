#!/bin/bash
# Pushes xochitl's notebooks to the Folio server (all of them): the files
# changed since the last good push as a tar, then the full list so the server
# drops what was deleted. From folio-notes-push.timer.
set -eu
src=/home/root/.local/share/remarkable/xochitl
state=/home/root/.local/state/folio-notes
# a setting from the same file as the app
conf() {
  { grep -E "^(export )?$1=" /home/root/.config/folio/folio.env 2>/dev/null || true; } |
    tail -n 1 | sed -E "s/^(export )?$1=//; s/^[\"']//; s/[\"']\$//"
}
server=$(conf FOLIO_SERVER_URL)
url=${server:-http://127.0.0.1:18082}
url=${url%/}/v1/notes
key="x-api-key: $(conf FOLIO_SERVER_TOKEN)"
# the server accepts the same names
keep='^[0-9a-f-]{36}(\.(metadata|content|pagedata|pdf|epub)|/[0-9a-f-]{36}\.rm)$'

mkdir -p "$state"
cd "$src"

# stamped before listing: a file xochitl writes during the push goes again
touch "$state/next"
find . -type f | sed 's|^\./||' | grep -E "$keep" | sort >"$state/all"
if [ -e "$state/pushed" ]; then
  find . -type f -newer "$state/pushed" | sed 's|^\./||' | grep -E "$keep" >"$state/changed" || true
else
  cp "$state/all" "$state/changed"
fi

if [ -s "$state/changed" ]; then
  # busybox wget posts a file as a C string (cut at the first NUL)
  tar -cf - -T "$state/changed" | gzip -c | openssl base64 -A >"$state/push.b64"
  wget -q -O - --header "$key" --post-file "$state/push.b64" "$url/push?encoding=base64-gzip"
  echo
  rm -f "$state/push.b64"
fi
wget -q -O - --header "$key" --post-file "$state/all" "$url/manifest"
echo
mv "$state/next" "$state/pushed"
echo "folio-notes: pushed $(wc -l <"$state/changed") changed of $(wc -l <"$state/all") files"
