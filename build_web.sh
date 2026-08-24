#!/usr/bin/env bash
# Build the AweCraft web export into web/.
# CWD-independent: every path resolves against the repo root (the directory
# containing this script). Scratch goes to the PROJECT-LOCAL .scratch/.
# Note: when running under a sandbox that makes the real $HOME read-only,
# set XDG_DATA_HOME to a writable dir that contains a `godot/export_templates`
# symlink (Godot keeps user data + export templates there).
set -o pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/web"
mkdir -p "$ROOT/.scratch"
LOG="$ROOT/.scratch/awecraft-build-web.log"

STAMP_FILE="$ROOT/godot/core/build_id.gd"
STAMP_BACKUP="$ROOT/.scratch/build_id.gd.bak"
GIT_REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
BUILD_ID="${AWECRAFT_BUILD_ID:-$(date +%Y%m%d)-${GIT_REV}}"
cp "$STAMP_FILE" "$STAMP_BACKUP"
printf 'class_name Build\n\nconst ID := "%s"\n' "$BUILD_ID" > "$STAMP_FILE"
echo "stamping build id: $BUILD_ID"

"$HOME/tools/godot/godot" --headless --path "$ROOT/godot" --export-release "Web" "$ROOT/web/index.html" >"$LOG" 2>&1
rc=$?

cp "$STAMP_BACKUP" "$STAMP_FILE"
echo "--- build stamp restored ---"
tail -40 "$LOG"
echo "godot exit code: $rc"
if [ "$rc" -eq 0 ]; then
	echo "--- build artifacts ---"
	ls -la "$ROOT/web/"
fi
exit "$rc"
