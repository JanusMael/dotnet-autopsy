#!/bin/bash
# dsos-info — friendly summary of THIS image: the file-server build/version,
# the .NET SDK & runtimes, the Microsoft diagnostic tools and the
# non-Microsoft tools (all with versions), the project-set environment, and
# the baked symbol cache. Installed on PATH as `dsos-info` (the file server
# itself serves no version/about endpoint).
#
# Read-only. Safe to run anytime in an interactive session.

set -u
FS_DIR="${FILE_SERVER_DIR:-/fileserver}"
SYM="${SYMBOLS_CACHE:-${FILES_DIR:-/analysis}/symbols}"

rule() { printf '─%.0s' $(seq 1 70); echo; }
hdr()  { echo; rule; echo "  $*"; rule; }

# ver <label> <cmd> [args…] — first line of `cmd …`, trimmed and aligned.
ver() {
    local label="$1"; shift
    if command -v "$1" >/dev/null 2>&1; then
        local out
        out=$("$@" 2>&1 | head -1 | sed 's/[[:space:]]\+$//')
        printf "  %-20s %s\n" "${label}" "${out:-(no version output)}"
    else
        printf "  %-20s %s\n" "${label}" "(not installed)"
    fi
}

hdr "FILE SERVER"
# RELEASE.txt is the authoritative (and only reliable) version record:
# written at build time from the pinned release — FILESERVER_REPO/_VERSION
# → repo/version/asset/source_url/downloaded_at. The binary itself is a
# self-contained single-file ELF apphost: its managed assemblies are bundled
# inside the native host, so no AssemblyVersion / PE FileVersionInfo is
# readable from it, and the server exposes no version/about endpoint. Do not
# re-add a binary-probing fallback here — there is nothing in the file to read.
if [ -f "${FS_DIR}/RELEASE.txt" ]; then
    sed 's/^/  /' "${FS_DIR}/RELEASE.txt"
else
    echo "  (release metadata not recorded — see provenance.txt / build args)"
fi

hdr ".NET SDK & RUNTIMES"
if command -v dotnet >/dev/null 2>&1; then
    printf "  %-20s %s\n" "SDK version" "$(dotnet --version 2>/dev/null)"
    echo "  --- SDKs ---"
    dotnet --list-sdks 2>/dev/null | sed 's/^/  /'
    echo "  --- runtimes ---"
    dotnet --list-runtimes 2>/dev/null \
        | awk '{printf "  %-26s %s\n",$1,$2}'
else
    echo "  (dotnet not found)"
fi

hdr ".NET DIAGNOSTIC TOOLS  (Microsoft — installed to /opt/bin)"
# `dotnet tool list` is the single robust source (covers dotnet-counters/
# -dump/-gcdump/-sos/-stack/-trace/-symbol, dotnet-monitor, PowerShell) and
# avoids per-tool --version quirks (e.g. dotnet-symbol has no --version).
if command -v dotnet >/dev/null 2>&1; then
    dotnet tool list --tool-path /opt/bin 2>/dev/null | awk '
        NR<=2 { next }
        NF>=2 { pin=($1=="dotnet-monitor")?"   (pinned)":"";
                printf "  %-22s %s%s\n",$1,$2,pin }'
else
    echo "  (dotnet not found)"
fi

hdr "NON-MICROSOFT TOOLS"
ver "lldb"           lldb --version
ver "gdb"            gdb --version
ver "elfutils"       eu-readelf --version
ver "binutils"       objdump --version
ver "file"           file --version
ver "fresh (editor)" fresh --version
ver "btop (monitor)" btop --version
ver "nano"           nano --version
ver "less"           less --version

# Curated, project-set environment only — NOT infrastructural vars
# (PATH, DOTNET_ROOT, DOTNET_*, HOME, …). Two sections, as requested.
show() {
    local name="$1" val
    eval "val=\${$name-}"
    [ -n "${val}" ] && printf "  %-22s = %s\n" "${name}" "${val}" \
        || printf "  %-22s = (unset)\n" "${name}"
}

hdr "ENVIRONMENT — post-mortem analysis"
for v in FILES_DIR CASE_DUMP CASE_OUTPUT SYMBOLS_CACHE \
         DOTNET_PerfMapEnabled DOTNET_EnableEventLog \
         DOTNET_SDK_IMAGE INNER_EXCEPTION_DEPTH SMOKE_TEST; do show "$v"; done

hdr "ENVIRONMENT — file server"
for v in FILE_SERVER_DIR; do show "$v"; done
echo "  serve config           = --root ${FILES_DIR:-/analysis} --route analysis --http-port 5550"
echo "  url                    = http://localhost:5550/"

hdr "SYMBOL CACHE  (${SYM})"
if [ -d "${SYM}" ]; then
    n=$(find "${SYM}" -type f 2>/dev/null | wc -l | tr -d ' ')
    sz=$(du -sh "${SYM}" 2>/dev/null | cut -f1)
    nso=$(find "${SYM}" -type f -name '*.so' 2>/dev/null | wc -l | tr -d ' ')
    echo "  files                  = ${n}  (${nso} .so)"
    echo "  size                   = ${sz:-unknown}"
    echo "  DAC present            = $(find "${SYM}" -name 'libmscordaccore*.so' \
        -o -name 'libcoreclr.so' 2>/dev/null | head -1 | grep -q . \
        && echo yes || echo 'no (see analysis.txt)')"
else
    echo "  (no symbol cache directory — analysis may not have run)"
fi
rule
