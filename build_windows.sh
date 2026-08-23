#!/usr/bin/env bash
# One-command Windows export pipeline for AweCraft (mirrors build_web.sh).
#
#   ./build_windows.sh              export release + debug-console,
#                                   then (re)start the LAN download daemon
#   ./build_windows.sh --no-serve   export only, leave the daemon alone
#
# Artifacts (NOT committed; exports/ is git-ignored):
#   exports/windows/AweCraft.exe               release build (run this)
#   exports/windows/AweCraft_debug_console.exe debug build (engine logs on)
#   exports/windows/AweCraft_debug_console.console.exe
#        Godot's console wrapper (it strips the final extension of the export
#        path with String::basename, hence this name). Double-click THIS on
#        Windows to get the game's logs in a console window (it launches the
#        debug exe with an allocated console and waits for it). Must sit next
#        to the debug exe.
#   exports/windows/BUILD.txt                  git sha + branch + stamp
#
# Download server: plain HTTP (python3 -m http.server) serving exports/windows/,
# setsid-detached daemon (survives session ends), pidfile
# .scratch/serve_win_export.pid, log .scratch/awecraft-winexport-http.log,
# port 8080 (falls back to 8081/8082, prints the picked port).
set -o pipefail

GODOT="$HOME/tools/godot/godot"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/AweCraft"
SCRATCH="$PROJECT/.scratch"
EXPORT_DIR="$PROJECT/exports/windows"
RELEASE_EXE="$EXPORT_DIR/AweCraft.exe"
DEBUG_EXE="$EXPORT_DIR/AweCraft_debug_console.exe"
# godot names the wrapper <basename-without-.exe>.console.exe
WRAPPER_EXE="${DEBUG_EXE%.exe}.console.exe"
TEMPLATE_DIR="$HOME/.local/share/godot/export_templates/4.7.1.stable"
LOG="$SCRATCH/awecraft-build-winexport.log"
DBG_LOG="$SCRATCH/awecraft-build-winexport-dbg.log"
PIDFILE="$SCRATCH/serve_win_export.pid"
SERVER_LOG="$SCRATCH/awecraft-winexport-http.log"
PORTS="8080 8081 8082"

NO_SERVE=0
for arg in "$@"; do
	case "$arg" in
	--no-serve) NO_SERVE=1 ;;
	*) echo "unknown option: $arg (supported: --no-serve)"; exit 2 ;;
	esac
done

cd "$PROJECT" || exit 1
mkdir -p "$EXPORT_DIR" "$SCRATCH"

die() { echo "FAIL: $*" >&2; exit 1; }
tail_log() { [ -f "$1" ] && tail -25 "$1" >&2; }

# ------------------------------------------------------------------- helpers

pe_report() {
	# Parse a PE from Linux: subsystem (2 = Windows GUI, 3 = Windows CUI/console)
	# + section names. This is how the console variant is proven without
	# running the exe: the console wrapper carries subsystem 3 (CUI) and the
	# main exes carry a reserved `pck` section holding the embedded game.
	python3 - "$1" <<'PYEOF'
import struct, sys
try:
    d = open(sys.argv[1], "rb").read()
except OSError:
    print("unreadable"); sys.exit(0)
if d[:2] != b"MZ":
    print("not-mz"); sys.exit(0)
off = struct.unpack_from("<I", d, 0x3c)[0]
if d[off:off + 4] != b"PE\x00\x00":
    print("no-pe"); sys.exit(0)
magic = struct.unpack_from("<H", d, off + 24)[0]
sub = struct.unpack_from("<H", d, off + 24 + (68 if magic == 0x20b else 60))[0]
nsec = struct.unpack_from("<H", d, off + 6)[0]
sopt = struct.unpack_from("<H", d, off + 20)[0]
secs = []
for i in range(nsec):
    b = off + 24 + sopt + i * 40
    secs.append(d[b:b + 8].rstrip(b"\0").decode("latin1"))
subname = {2: "GUI (no console)", 3: "CUI (console)"}.get(sub, "subsystem=%d" % sub)
print("%s; sections[%s]" % (subname, ",".join(secs)))
PYEOF
}

check_exe() {
	# $1=file $2=label $3=required substring of the pe_report output
	local f="$1" label="$2" must_have="$3"
	[ -f "$f" ] || die "$label: missing $f"
	local magic; magic="$(head -c2 "$f")"
	[ "$magic" = "MZ" ] || die "$label: not a PE executable (magic '${magic}') — export produced garbage"
	local info; info="$(pe_report "$f")"
	case "$info" in
	*"$must_have"*) : ;;
	*) die "$label: PE check failed — expected '$must_have', got: $info" ;;
	esac
	echo "  $label: $(basename "$f")  size=$(stat -c%s "$f")  [${info}]"
}

# ------------------------------------------------------------------ 1. release

echo "=== AweCraft Windows export ==="
echo "[1/2] export release      -> exports/windows/AweCraft.exe  (preset \"Windows\")"
"$GODOT" --headless --path godot --export-release "Windows" \
	"$RELEASE_EXE" >"$LOG" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
	echo "godot release export FAILED (exit $rc)" >&2; tail_log "$LOG"; exit 1
fi
echo "  release export ok"

# ---------------------------------------------------------- 2. debug + console

echo "[2/2] export debug+console -> exports/windows/AweCraft_debug_console.exe (preset \"Windows (console debug)\")"
echo "      (Godot 4.7 console builds = normal debug exe + a .console.exe wrapper"
echo "       copied next to it when debug/export_console_wrapper=1 — see spec notes)"
"$GODOT" --headless --path godot --export-debug "Windows (console debug)" \
	"$DEBUG_EXE" >"$DBG_LOG" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
	echo "godot debug-console export FAILED (exit $rc)" >&2; tail_log "$DBG_LOG"; exit 1
fi
echo "  debug-console export ok"

# ------------------------------------------------------------------- verify

echo "--- verification ---"
check_exe "$RELEASE_EXE" "release  " "pck"
check_exe "$DEBUG_EXE"   "dbg-main " "pck"
check_exe "$WRAPPER_EXE" "wrapper  " "CUI (console)"

[ "$(stat -c%s "$RELEASE_EXE")" -lt 10485760 ] && \
	echo "  WARN: release exe under 10MB — suspicious export"

# release and debug builds must be distinct binaries
if [ "$(sha256sum "$RELEASE_EXE" | cut -d' ' -f1)" = "$(sha256sum "$DEBUG_EXE" | cut -d' ' -f1)" ]; then
	die "release and debug builds are byte-identical — export bug"
fi
echo "  release and debug exes are distinct (sha256 differ)"

# console-variant proof (Linux can't run the exe): compare the exported
# wrapper PE section-by-section with the Godot console template. The editor
# copies the template and strips its bundled .rsrc icon/version resources, so
# identity = every non-rsrc section byte-identical + CUI subsystem.
WRAPPER_TMPL="$TEMPLATE_DIR/windows_debug_x86_64_console.exe"
if [ -f "$WRAPPER_TMPL" ]; then
	python3 - "$WRAPPER_EXE" "$WRAPPER_TMPL" <<'PYEOF'
import struct, sys

def secs(path):
    d = open(path, "rb").read()
    off = struct.unpack_from("<I", d, 0x3c)[0]
    nsec = struct.unpack_from("<H", d, off + 6)[0]
    sopt = struct.unpack_from("<H", d, off + 20)[0]
    out = {}
    for i in range(nsec):
        b = off + 24 + sopt + i * 40
        name = d[b:b + 8].rstrip(b"\0").decode("latin1")
        vs, va, rs, ro = struct.unpack_from("<IIII", d, b + 8)
        out[name] = (rs, ro)
    return d, out

a, sa = secs(sys.argv[1])
b, sb = secs(sys.argv[2])
matched = 0
total = 0
for name in sa:
    if name not in sb or name in (".bss", ".rsrc", ".reloc"):
        continue
    rs, ro = sa[name]
    if rs == 0:
        continue
    if a[ro:ro + rs] != b[sb[name][1]:sb[name][1] + rs]:
        sys.exit(1)  # section mismatch -> shell treats as failure
    matched += 1
    total += rs
if matched == 0:
    sys.exit(1)
print("OK: %d sections byte-identical to console template (%d bytes)" % (matched, total))
PYEOF
	case "$?" in
	0) : ;;
	*) die "wrapper sections differ from the console template — not the console variant" ;;
	esac
	echo "  console proven: wrapper is windows_debug_x86_64_console.exe template code"
	echo "    (PE sections byte-identical; editor only strips bundled .rsrc resources"
	echo "    141912->3296 and adjusts PE size fields, per godot 4.7 prepare_template)"
else
	echo "  WARN: console template not found at $WRAPPER_TMPL — wrapper identity not cross-checked"
fi

GIT_REV="$(git -C "$PROJECT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
GIT_BRANCH="$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo nobranch)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"$EXPORT_DIR/BUILD.txt" <<EOF
AweCraft Windows build
git:    $GIT_REV ($GIT_BRANCH)
time:   $TS
run:    AweCraft.exe  (release, preset "Windows", --export-release)
logs:   AweCraft_debug_console.console.exe  (console wrapper — double-click;
         it launches AweCraft_debug_console.exe with a console)
EOF
echo "  BUILD.txt:"
sed 's/^/    /' "$EXPORT_DIR/BUILD.txt"
echo "--- artifacts ---"
ls -la "$EXPORT_DIR"

# --------------------------------------------------------------------- serve

lan_ip() {
	python3 - <<'PY'
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    print(s.getsockname()[0]); s.close()
except OSError:
    print("192.168.0.224")
PY
}

print_urls() {
	local port="$1" ip
	ip="$(lan_ip)"
	echo
	echo "Windows downloads (from a Windows machine on this LAN):"
	echo "  release (single file):"
	echo "    http://localhost:$port/AweCraft.exe"
	echo "    http://$ip:$port/AweCraft.exe"
	echo "  debug console (download BOTH files, same folder on the"
	echo "    Windows machine; double-click the wrapper for logs):"
	echo "    http://localhost:$port/AweCraft_debug_console.exe"
	echo "    http://localhost:$port/AweCraft_debug_console.console.exe"
	echo "    (file listing: http://$ip:$port/)"
}

# find the pid of a live 'python3 -m http.server' serving EXPORT_DIR ("" if none)
find_our_server() {
	local d p cmd
	for d in /proc/[0-9]*; do
		p="${d#/proc/}"
		[ -r "$d/cmdline" ] || continue
		cmd="$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)"
		case "$cmd" in
		*"http.server"*"$EXPORT_DIR"*) echo "$p"; return 0 ;;
		esac
	done
	return 1
}

# port of the http.server process with the given pid (from its cmdline)
port_of_pid() {
	tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null | awk '$0=="http.server"{getline; print; exit}'
}

port_busy() {
	[ -n "$(ss -Htln "sport = :$1" 2>/dev/null | head -1)" ]
}

start_server() {
	local found port p
	found="$(find_our_server || true)"
	if [ -n "$found" ]; then
		port="$(port_of_pid "$found")"
		echo "download server already running (pid $found, port $port) — leaving it up"
		print_urls "$port"
		return 0
	fi

	# no live server: the pidfile, if any, is stale (dead or pid-reused) -> clear
	if [ -f "$PIDFILE" ]; then
		local fp; fp="$(cat "$PIDFILE" 2>/dev/null)"
		if [ -n "$fp" ] && [ -d "/proc/$fp" ]; then
			echo "pidfile points at live pid $fp that is not the export http server — stale, clearing"
		elif [ -n "$fp" ]; then
			echo "pidfile stale (pid $fp dead) — clearing"
		fi
		rm -f "$PIDFILE"
	fi

	port=""
	for p in $PORTS; do
		if port_busy "$p"; then
			echo "port $p busy — trying next"
		else
			port="$p"
			break
		fi
	done
	[ -n "$port" ] || die "no free port in $PORTS for the download server"

	setsid python3 -m http.server "$port" --bind 0.0.0.0 --directory "$EXPORT_DIR" \
		</dev/null >>"$SERVER_LOG" 2>&1 &
	sleep 1
	found="$(find_our_server || true)"
	[ -n "$found" ] || die "download server failed to start on port $port; see $SERVER_LOG"
	echo "$found" >"$PIDFILE"
	echo "download server started (pid $found, port $port, log $SERVER_LOG, pidfile $PIDFILE)"
	print_urls "$port"
	return 0
}

if [ "$NO_SERVE" = 1 ]; then
	echo "--no-serve: skipping download daemon"
else
	start_server || exit 1
fi
echo "=== done ==="
exit 0
