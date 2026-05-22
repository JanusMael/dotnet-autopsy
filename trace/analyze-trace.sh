#!/bin/bash
# trace/analyze-trace.sh - build-time trace analysis (dotnet-autopsy · trace).
# Mirror of sos/analyze.sh structure, but for `.nettrace` captures from
# `dotnet-trace collect`. Same failure-tolerant philosophy: individual
# steps may fail but the image always builds (soft_fail writes a banner
# and exits 0) and the container remains attachable.
#
# Required env (set in Dockerfile ARG→ENV):
#   CASE_TRACE        — absolute path to the baked .nettrace
#   FILES_DIR         — /analysis
#   CASE_OUTPUT       — /analysis/analysis.txt
#   DOTNET_SDK_IMAGE  — base image tag (informational, written to provenance)
#
# v1 BCL-first scope: top-CPU triage from `dotnet-trace report topN`.
# GC / alloc-by-type / contention / starvation require richer event parsing
# (TraceEvent) — deferred per plan.

set -uo pipefail   # tolerate individual step failures

CASE_TRACE="${CASE_TRACE:-/analysis/trace.nettrace}"
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
CASE_DUMP="${CASE_TRACE}"            # path of the artifact
DUMP_ARCH_DETECTED="${DUMP_ARCH_DETECTED:-unknown}"
CONTAINER_ARCH="$(uname -m)"
ARCH_MATCH=true                      # traces are arch-portable enough for v1
DUMP_FIDELITY="full-or-triage"
RUNTIME_VERSION="unknown"
DAC_SOURCE="n/a (trace)"             # no DAC for traces

mkdir -p "${FILES_DIR}" "${USER_SYMBOLS}"

# ── helpers + shared assemble/finalize/render building blocks ────────────────
source /opt/lib/analyze-common.sh

# ── 1. Trace file exists? ────────────────────────────────────────────────────

banner "Step 1/5 — Trace file check"

[ -f "${CASE_TRACE}" ] || soft_fail "Trace not found: ${CASE_TRACE}"

TRACE_SIZE=$(stat -c%s "${CASE_TRACE}" 2>/dev/null || echo "0")
echo "Trace : ${CASE_TRACE}"
echo "Size  : ${TRACE_SIZE} bytes"

# Very small file → likely empty/corrupt capture; degraded but continue.
if [ "${TRACE_SIZE}" -lt 4096 ]; then
    DUMP_FIDELITY="degraded"
    warn "Very small trace (${TRACE_SIZE} B). Likely empty capture or wrong format."
fi

# ── 2. Container arch (informational only — traces are not DAC-gated) ────────

banner "Step 2/5 — Container architecture"

# Map uname -m to the docker-style arch label that sos uses, for status
# schema consistency. Trace is not actually gated on arch (no DAC).
case "${CONTAINER_ARCH}" in
    x86_64)  DUMP_ARCH_DETECTED="x86_64" ;;
    aarch64) DUMP_ARCH_DETECTED="aarch64" ;;
    *)       DUMP_ARCH_DETECTED="${CONTAINER_ARCH}" ;;
esac
echo "Container arch : ${CONTAINER_ARCH}"
echo "Trace arch     : ${DUMP_ARCH_DETECTED}  (informational; not DAC-gated)"

# ── 2.5 Runtime version probe via TraceEvent ────────────────────────────────
# trace_triage embeds Microsoft.Diagnostics.Tracing.TraceEvent so it can read
# the .NET runtime version from the .nettrace's rundown events. Probe BEFORE
# Step 3 writes provenance so the rendered H1 reflects the real version
# instead of "unknown". Best-effort: missing/unreadable trace leaves
# RUNTIME_VERSION at its initial "unknown" and the rest of the pipeline
# carries on as before.
if [ -f "${CASE_TRACE}" ] && [ -x /opt/report-bin/trace_triage/trace_triage ]; then
    PROBED_RT=$(/opt/report-bin/trace_triage/trace_triage --probe-runtime "${CASE_TRACE}" 2>/dev/null || true)
    if [ -n "${PROBED_RT}" ]; then
        RUNTIME_VERSION="${PROBED_RT}"
        echo "Runtime (TraceEvent rundown probe): ${RUNTIME_VERSION}"
    fi
fi

# ── 3. Provenance record ─────────────────────────────────────────────────────

banner "Step 3/5 — Provenance"

TRACE_SHA256=$(sha256sum "${CASE_TRACE}" 2>/dev/null | awk '{print $1}' || echo "unknown")
BUILD_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DN_VER=$(dotnet --version 2>/dev/null || echo "unknown")
DT_VER=$(dotnet-trace --version 2>/dev/null || echo "unknown")
DMON_VER=$(dotnet tool list --tool-path /opt/bin 2>/dev/null | awk '/dotnet-monitor/{print $2}')
[ -z "${DMON_VER}" ] && DMON_VER="unknown"

cat > "${PROV_FILE}" << PROVEOF
# Provenance — dotnet-autopsy/trace analysis image
# Re-pin any value via --build-arg to reproduce this exact environment.
# Generated: ${BUILD_TS}

report_tool       : dotnet-trace
base_image_tag    : ${DOTNET_SDK_IMAGE:-unknown}
dotnet_sdk        : ${DN_VER}
dotnet-trace      : ${DT_VER}
dotnet-monitor    : ${DMON_VER}  (pinned)
trace_sha256      : ${TRACE_SHA256}
trace_size_bytes  : ${TRACE_SIZE}
dump_arch         : ${DUMP_ARCH_DETECTED}
container_arch    : ${CONTAINER_ARCH}
runtime_version   : ${RUNTIME_VERSION}
trace_fidelity    : ${DUMP_FIDELITY}
build_timestamp   : ${BUILD_TS}
PROVEOF

cat "${PROV_FILE}"

# ── 4. dotnet-trace analysis (BCL-first: report topN + convert speedscope) ───

banner "Step 4/5 — dotnet-trace analysis"

# Embed a kv header trace_triage.cs reads for the TRACE METADATA section.
{
    echo "trace_file_path: ${CASE_TRACE}"
    echo "trace_file_size: ${TRACE_SIZE}"
    echo ""
} > "${RAW_TMP}"

# `dotnet-trace report topN`  (only subcommand of `report` in current
# dotnet-trace; sufficient for v1 top-CPU triage — see RUNBOOK).
echo "=== dotnet-trace report topN ==="
{
    echo "=== dotnet-trace report topN -n 25 ==="
    dotnet-trace report "${CASE_TRACE}" topN -n 25 2>&1 || true
    echo ""
} >> "${RAW_TMP}"

# `dotnet-trace convert -o BASE --format speedscope` writes
# BASE.speedscope.json (suffix appended — naming gotcha; see RUNBOOK).
# v1 just records the convert log; the speedscope JSON itself stays on
# disk for richer follow-up analysis (a TraceEvent / folded-stack pass).
SS_BASE="${FILES_DIR}/trace"
echo "=== dotnet-trace convert --format speedscope ==="
{
    echo "=== dotnet-trace convert --format speedscope ==="
    dotnet-trace convert "${CASE_TRACE}" --format speedscope -o "${SS_BASE}" 2>&1 || true
    if [ -f "${SS_BASE}.speedscope.json" ]; then
        SSZ=$(stat -c%s "${SS_BASE}.speedscope.json" 2>/dev/null || echo "0")
        echo "speedscope_file : ${SS_BASE}.speedscope.json (${SSZ} bytes)"
    else
        echo "speedscope_file : (not produced)"
    fi
    echo ""
} >> "${RAW_TMP}"

echo "Raw trace output: $(wc -l < "${RAW_TMP}") lines"

# Judge analysis health from RAW: must contain the topN header to count as
# real signal. Failure modes mirror sos: ANALYSIS_BROKEN set → status=failed.
ANALYSIS_BROKEN=false
FAIL_REASON=""
if grep -qE "is not a valid trace|Failed to|Error reading|Unhandled exception" "${RAW_TMP}" 2>/dev/null; then
    ANALYSIS_BROKEN=true
    FAIL_REASON="dotnet-trace report/convert reported a failure on the trace."
fi
HAS_REAL_SOS=false   # reused flag name for analyze-common.finalize_status
# POSIX `grep -E` does not support `\d`; use [0-9]+. (trace_triage.cs uses
# .NET Regex, which does support \d — that one stays as-is.)
if grep -qE "^Top [0-9]+ Functions \(Exclusive\)" "${RAW_TMP}" 2>/dev/null; then
    HAS_REAL_SOS=true
fi
if [ "${ANALYSIS_BROKEN}" = true ]; then
    DUMP_FIDELITY="degraded"
elif [ "${HAS_REAL_SOS}" = false ]; then
    warn "No topN block detected — trace may be empty or not cpu-sampling."
    DUMP_FIDELITY="degraded"
fi
sed -i "s/^trace_fidelity.*/trace_fidelity    : ${DUMP_FIDELITY}/" "${PROV_FILE}" 2>/dev/null || true

# Actionable banner if the trace is unusable.
: > "${LOWFI_TMP}"
if [ "${ANALYSIS_BROKEN}" = true ]; then
    warn "${FAIL_REASON}"
    {
        echo "════════════════════════════════════════════════════════════"
        echo "  ⚠  ANALYSIS DEGRADED — TRACE FILE UNUSABLE"
        echo "════════════════════════════════════════════════════════════"
        echo "  ${FAIL_REASON}"
        echo ""
        echo "  Re-capture a cpu-sampling trace at the origin, then rebuild:"
        echo "    dotnet-trace collect --format nettrace -o trace.nettrace -p <pid>"
        echo "    dotnet-trace collect --format nettrace -o trace.nettrace -- <command>"
        echo ""
        echo "  See trace/RUNBOOK.md § Capturing a usable .nettrace."
        echo "════════════════════════════════════════════════════════════"
        echo ""
    } > "${LOWFI_TMP}"
fi

# ── 5. Trace triage summary ──────────────────────────────────────────────────

banner "Step 5/5 — Trace triage summary"

# 7th arg = speedscope JSON path (optional); trace_triage parses
# profiles[0].samples + endValue-startValue for sample_count + duration_ms.
# Pass empty if convert didn't produce one — trace_triage handles absence.
# 8th arg = the .nettrace itself (optional). When present AND the file
# parses, trace_triage walks the EventPipe stream via TraceEvent (NuGet
# in the trace triage csproj) to add runtime_version, GC SUMMARY and
# EXCEPTION COUNTS sections. Any TraceEvent failure leaves the depth
# sections OMITTED → BCL-only baseline (parity gate's deterministic
# mode; fixtures never pass this argv).
SS_JSON="${SS_BASE}.speedscope.json"
[ -f "${SS_JSON}" ] || SS_JSON=""
NT_FILE="${CASE_TRACE}"
[ -f "${NT_FILE}" ] || NT_FILE=""
/opt/report-bin/trace_triage/trace_triage \
    "${RAW_TMP}" "${RUNTIME_VERSION}" "${DUMP_ARCH_DETECTED}" \
    "${DUMP_FIDELITY}" "dotnet-trace ${DT_VER}" "${BUILD_TS}" \
    "${SS_JSON}" "${NT_FILE}" \
    > "${TRIAGE_TMP}" 2>/dev/null \
    || { warn "Trace triage failed — raw output still available."; echo "(trace triage unavailable)" > "${TRIAGE_TMP}"; }

# ── Assemble + status + render (shared building blocks) ──────────────────────
assemble_output
finalize_status
render_md_and_banner

exit 0
