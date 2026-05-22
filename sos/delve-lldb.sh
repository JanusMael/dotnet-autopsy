#!/bin/bash
# delve-lldb — lldb + SOS wrapper for the baked core dump.
#
# WHY THIS EXISTS: unlike `dotnet-dump analyze` (the `delve` wrapper), raw lldb
# must be given the executable that produced the core — exactly like gdb with a
# core file. With only `lldb -c <core>`, lldb reports "the target has no
# associated executable images", so SOS has no module list and fails with
# "Failed to find runtime module (libcoreclr.so), 0x80004002". With the right
# executable, lldb reconstructs the module list (incl. libcoreclr.so) and SOS
# binds the DAC normally. (dotnet-dump avoids this by using createdump's
# embedded SpecialDiagInfoHeader instead of lldb's module reconstruction.)
#
# This wrapper finds the executable automatically:
#   1. the path the core records (execfn) if present in the image
#      — covers framework-dependent apps: execfn=/usr/bin/dotnet, always present
#   2. that basename under /symbols-user (drop your app binary in ./symbols/)
#      then under /analysis
# SOS itself auto-loads via ~/.lldbinit (plugin load + setsymbolserver -ms).
#
# Usage:  delve-lldb [/path/to/dump]   (defaults to $CASE_DUMP)

set -u

DUMP="${CASE_DUMP:-/analysis/core.dump}"
if [ "$#" -gt 0 ]; then
    case "$1" in
        /*|./*) DUMP="$1"; shift ;;
    esac
fi

if [ ! -f "$DUMP" ]; then
    echo "delve-lldb: dump not found: $DUMP" >&2
    exit 1
fi

# Executable path the ELF core records (e.g. /usr/bin/dotnet, or an apphost).
EXECFN="$(file "$DUMP" 2>/dev/null \
    | grep -oE "execfn: '[^']+'" | head -1 \
    | sed "s/execfn: '//; s/'$//")"
BASE="$(basename "${EXECFN:-}" 2>/dev/null || true)"

EXE=""
# 1. exact recorded path (covers `dotnet App.dll` — /usr/bin/dotnet is in-image)
if [ -n "${EXECFN:-}" ] && [ -x "$EXECFN" ]; then
    EXE="$EXECFN"
fi
# 2. by basename under user-supplied binaries, then the analysis dir
#    (no depth limit — users may preserve a nested publish tree; these dirs
#    are small. The recorded path can be arbitrarily deep, e.g.
#    /app/bin/Release/net10.0/MyApp or .../bin/Debug/net10.0/a.)
if [ -z "$EXE" ] && [ -n "$BASE" ]; then
    EXE="$(find /symbols-user /analysis -type f -name "$BASE" 2>/dev/null | head -1)"
fi

if [ -z "$EXE" ]; then
    cat >&2 <<MSG
delve-lldb: could not locate the application executable for this dump.

  The core records its executable as:
      ${EXECFN:-<unknown>}

  Raw lldb needs that binary to load the core (a normal core-file
  requirement). dotnet-dump does NOT — for managed analysis just run:

      delve

  To use lldb+SOS instead: copy your app's executable (the apphost /
  published binary) into ./symbols/ before building — it is baked into
  /symbols-user — then re-run:  delve-lldb
MSG
    exit 1
fi

echo "delve-lldb: lldb $EXE -c $DUMP" >&2
echo "delve-lldb: SOS auto-loads (~/.lldbinit). Try: clrthreads, clrstack, pe" >&2
exec lldb "$EXE" -c "$DUMP" "$@"
