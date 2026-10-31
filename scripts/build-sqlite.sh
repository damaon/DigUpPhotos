#!/bin/bash
# SQLite (public domain) for Windows, which has none to link against: the amalgamation at a pinned version and SHA-256
# into Vendor/sqlite, compiled by SwiftPM as the CSQLite target, with FTS5 (the index's word search). macOS ships
# SQLite and Linux has libsqlite3-dev, so neither needs this. Does nothing when it's there already.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=3500400
SHA=1d3049dd0f830a025a53105fc79fd2ab9431aea99e137809d064d8ee8356b032
OUT=Vendor/sqlite
[[ "$(cat "$OUT/BUILD" 2>/dev/null)" == "$VERSION" ]] && exit 0
sha() { (command -v sha256sum > /dev/null && sha256sum "$1" || shasum -a 256 "$1") | cut -d' ' -f1; }
mkdir -p Vendor
ZIP=Vendor/sqlite-$VERSION.zip
curl --fail --silent --show-error --location -o "$ZIP" "https://www.sqlite.org/2025/sqlite-amalgamation-$VERSION.zip"
[[ "$(sha "$ZIP")" == "$SHA" ]] || { echo "$ZIP: wrong SHA-256" >&2; rm -f "$ZIP"; exit 1; }
rm -rf "$OUT" Vendor/sqlite-amalgamation-$VERSION && mkdir -p "$OUT/include"
unzip -q "$ZIP" -d Vendor
mv Vendor/sqlite-amalgamation-$VERSION/sqlite3.c Vendor/sqlite-amalgamation-$VERSION/sqlite3.h "$OUT/"
rm -rf "$ZIP" Vendor/sqlite-amalgamation-$VERSION
# The module's umbrella header: SwiftPM names the module after the target, CSQLite, as on Linux.
printf '#include "../sqlite3.h"\n' > "$OUT/include/CSQLite.h"
echo "$VERSION" > "$OUT/BUILD"
echo "Fetched SQLite $VERSION into $OUT"
