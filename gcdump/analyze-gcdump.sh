#!/bin/bash
# gcdump/analyze-gcdump.sh - build-time gcdump analysis (dotnet-autopsy · gcdump).
# Sibling of sos/analyze.sh and trace/analyze-trace.sh; reads a .gcdump file
# captured by `dotnet-gcdump collect` (a managed heap snapshot, not a core
# dump and not a perf trace).
#
# Required env (set in Dockerfile ARG→ENV):
#   CASE_GCDUMP       — absolute path to the baked .gcdump
#   FILES_DIR         — /analysis
#   CASE_OUTPUT       — /analysis/analysis.txt
#   DOTNET_SDK_IMAGE  — base image tag (informational, written to provenance)
#
# v1 scope (BCL-only triage): parse `dotnet-gcdump report` text → HEAP
# SUMMARY + TOP TYPES BY SIZE + HEURISTIC WARNINGS. Same failure-tolerant
# philosophy as the siblings.

set -uo pipefail

CASE_GCDUMP="${CASE_GCDUMP:-/analysis/heap.gcdump}"
FILES_DIR="${FILES_DIR:-/analysis}"
CASE_OUTPUT="${CASE_OUTPUT:-${FILES_DIR}/analysis.txt}"
USER_SYMBOLS="/symbols-user"
STATUS_FILE="${FILES_DIR}/status.json"
PROV_FILE="${FILES_DIR}/provenance.txt"
TRIAGE_TMP="${FILES_DIR}/.triage.tmp"
RAW_TMP="${FILES_DIR}/.analysis_raw.tmp"
LOWFI_TMP="${FILES_DIR}/.lowfi.tmp"

# analyze-common.sh's write_status reads these (originally dump-specific
# names; we reuse them to keep status.json schema-stable across siblings).
CASE_DUMP="${CASE_GCDUMP}"
DUMP_ARCH_DETECTED="${DUMP_ARCH_DETECTED:-unknown}"
CONTAINER_ARCH="$(uname -m)"
ARCH_MATCH=true                  # gcdumps are arch-portable enough for v1
DUMP_FIDELITY="full-or-triage"
RUNTIME_VERSION="unknown"
DAC_SOURCE="n/a (gcdump)"        # no DAC for gcdumps

mkdir -p "${FILES_DIR}" "${USER_SYMBOLS}"

# ── helpers + shared assemble/finalize/render building blocks ───────────────
source /opt/lib/analyze-common.sh

# ── 1. gcdump file exists? ──────────────────────────────────────────────────

banner "Step 1/5 — gcdump file check"

[ -f "${CASE_GCDUMP}" ] || soft_fail "gcdump not found: ${CASE_GCDUMP}"

GCDUMP_SIZE=$(stat -c%s "${CASE_GCDUMP}" 2>/dev/null || echo "0")
echo "gcdump : ${CASE_GCDUMP}"
echo "Size   : ${GCDUMP_SIZE} bytes"

if [ "${GCDUMP_SIZE}" -lt 4096 ]; then
    DUMP_FIDELITY="degraded"
    warn "Very small gcdump (${GCDUMP_SIZE} B). Likely empty/corrupt capture."
fi

# ── 2. Container arch (informational; gcdump is arch-portable) ───────────────

banner "Step 2/5 — Container architecture"

case "${CONTAINER_ARCH}" in
    x86_64)  DUMP_ARCH_DETECTED="x86_64" ;;
    aarch64) DUMP_ARCH_DETECTED="aarch64" ;;
    *)       DUMP_ARCH_DETECTED="${CONTAINER_ARCH}" ;;
esac
echo "Container arch : ${CONTAINER_ARCH}"
echo "Gcdump arch    : ${DUMP_ARCH_DETECTED}  (informational; gcdumps are portable)"

# ── 3. Provenance record ────────────────────────────────────────────────────

banner "Step 3/5 — Provenance"

GCDUMP_SHA256=$(sha256sum "${CASE_GCDUMP}" 2>/dev/null | awk '{print $1}' || echo "unknown")
BUILD_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DN_VER=$(dotnet --version 2>/dev/null || echo "unknown")
DG_VER=$(dotnet-gcdump --version 2>/dev/null || echo "unknown")
DMON_VER=$(dotnet tool list --tool-path /opt/bin 2>/dev/null | awk '/dotnet-monitor/{print $2}')
[ -z "${DMON_VER}" ] && DMON_VER="unknown"

cat > "${PROV_FILE}" << PROVEOF
# Provenance — dotnet-autopsy · gcdump analysis image
# Re-pin any value via --build-arg to reproduce this exact environment.
# Generated: ${BUILD_TS}

base_image_tag    : ${DOTNET_SDK_IMAGE:-unknown}
dotnet_sdk        : ${DN_VER}
dotnet-gcdump     : ${DG_VER}
dotnet-monitor    : ${DMON_VER}  (pinned)
report_tool       : dotnet-gcdump
gcdump_sha256     : ${GCDUMP_SHA256}
gcdump_size_bytes : ${GCDUMP_SIZE}
container_arch    : ${CONTAINER_ARCH}
dump_arch         : ${DUMP_ARCH_DETECTED}
runtime_version   : ${RUNTIME_VERSION}
gcdump_fidelity   : ${DUMP_FIDELITY}
build_timestamp   : ${BUILD_TS}
PROVEOF

cat "${PROV_FILE}"

# ── 4. dotnet-gcdump report ─────────────────────────────────────────────────

banner "Step 4/5 — dotnet-gcdump analysis"

{
    echo "gcdump_file_path: ${CASE_GCDUMP}"
    echo "gcdump_file_size: ${GCDUMP_SIZE}"
    echo ""
    echo "=== dotnet-gcdump report ==="
    dotnet-gcdump report "${CASE_GCDUMP}" 2>&1 || true
    echo ""
} > "${RAW_TMP}"

echo "Raw gcdump output: $(wc -l < "${RAW_TMP}") lines"

# Health-judge for gcdump: looks for the "GC Heap bytes" header that
# dotnet-gcdump always emits when the file parses cleanly.
ANALYSIS_BROKEN=false
FAIL_REASON=""
if grep -qE "is not a valid|Failed to|Error reading|Unhandled exception" "${RAW_TMP}" 2>/dev/null; then
    ANALYSIS_BROKEN=true
    FAIL_REASON="dotnet-gcdump report reported a failure on the gcdump."
fi
HAS_REAL_SOS=false   # reused flag for analyze-common.finalize_status
if grep -qE "GC Heap bytes" "${RAW_TMP}" 2>/dev/null; then
    HAS_REAL_SOS=true
fi
if [ "${ANALYSIS_BROKEN}" = true ]; then
    DUMP_FIDELITY="degraded"
elif [ "${HAS_REAL_SOS}" = false ]; then
    warn "No 'GC Heap bytes' header detected — gcdump may be empty/corrupt."
    DUMP_FIDELITY="degraded"
fi
sed -i "s/^gcdump_fidelity.*/gcdump_fidelity   : ${DUMP_FIDELITY}/" "${PROV_FILE}" 2>/dev/null || true

: > "${LOWFI_TMP}"
if [ "${ANALYSIS_BROKEN}" = true ]; then
    warn "${FAIL_REASON}"
    {
        echo "════════════════════════════════════════════════════════════"
        echo "  ⚠  ANALYSIS DEGRADED — GCDUMP FILE UNUSABLE"
        echo "════════════════════════════════════════════════════════════"
        echo "  ${FAIL_REASON}"
        echo ""
        echo "  Re-capture a usable gcdump at the origin, then rebuild:"
        echo "    dotnet-gcdump collect -p <pid> -o heap.gcdump"
        echo ""
        echo "  See gcdump/RUNBOOK.md § Capturing a usable .gcdump."
        echo "════════════════════════════════════════════════════════════"
        echo ""
    } > "${LOWFI_TMP}"
fi

# ── 5. gcdump triage summary ────────────────────────────────────────────────

banner "Step 5/5 — gcdump triage summary"

/opt/report-bin/gcdump_triage/gcdump_triage \
    "${RAW_TMP}" "${RUNTIME_VERSION}" "${DUMP_ARCH_DETECTED}" \
    "${DUMP_FIDELITY}" "dotnet-gcdump ${DG_VER}" "${BUILD_TS}" \
    > "${TRIAGE_TMP}" 2>/dev/null \
    || { warn "gcdump triage failed — raw output still available."; echo "(gcdump triage unavailable)" > "${TRIAGE_TMP}"; }

# ── Assemble + status + render (shared building blocks) ─────────────────────
assemble_output
finalize_status
render_md_and_banner

exit 0
