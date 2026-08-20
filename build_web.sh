#!/usr/bin/env bash
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p AweCraft/web
mkdir -p "$ROOT/.scratch"
LOG="$ROOT/.scratch/awecraft-build-web.log"

STAMP_FILE="$ROOT/AweCraft/godot/core/build_id.gd"
STAMP_BACKUP="$ROOT/.scratch/build_id.gd.bak"
GIT_REV="$(git -C "$ROOT/AweCraft" rev-parse --short HEAD 2>/dev/null || echo nogit)"
BUILD_ID="${AWECRAFT_BUILD_ID:-$(date +%Y%m%d)-${GIT_REV}}"
cp "$STAMP_FILE" "$STAMP_BACKUP"
printf 'class_name Build\n\nconst ID := "%s"\n' "$BUILD_ID" > "$STAMP_FILE"
echo "stamping build id: $BUILD_ID"

~/tools/godot/godot --headless --path AweCraft/godot --export-release "Web" "$ROOT/AweCraft/web/index.html" >"$LOG" 2>&1
rc=$?

cp "$STAMP_BACKUP" "$STAMP_FILE"
echo "--- build stamp restored ---"
tail -40 "$LOG"
echo "godot exit code: $rc"
if [ "$rc" -eq 0 ]; then
	echo "--- build artifacts ---"
	ls -la AweCraft/web/
fi
exit "$rc"
