#!/usr/bin/env bash
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p AweCraft/web
mkdir -p "$ROOT/.scratch"
LOG="$ROOT/.scratch/awecraft-build-web.log"
~/tools/godot/godot --headless --path AweCraft/godot --export-release "Web" "$ROOT/AweCraft/web/index.html" >"$LOG" 2>&1
rc=$?
tail -40 "$LOG"
echo "godot exit code: $rc"
if [ "$rc" -eq 0 ]; then
	echo "--- build artifacts ---"
	ls -la AweCraft/web/
fi
exit "$rc"
