#!/bin/bash
# analyze.sh — build-time dump analysis.
# Runs inside the container during docker build. Failure-tolerant: individual
# SOS command failures write a banner but always exit 0 so the image builds
# and the container remains attachable for manual delving.
#
# Required env (set in Dockerfile ARG→ENV):
#   CASE_DUMP         — absolute path to the baked core dump
#   FILES_DIR         — /analysis
#   CASE_OUTPUT       — /analysis/analysis.txt
#   DOTNET_SDK_IMAGE  — base image tag (informational, written to provenance)
# Optional env (Dockerfile ARG→ENV; sensible default if unset):
#   INNER_EXCEPTION_DEPTH — max wrapped-inner-exception expansion passes
#                           (default 9; 0 disables). See § 6b.

set -uo pipefail   # deliberately NOT -e: we tolerate individual step failures

CASE_DUMP="${CASE_DUMP:-/analysis/core.dump}"
FILES_DIR="${FILES_DIR:-/analysis}"
CASE_OUTPUT="${CASE_OUTPUT:-${FILES_DIR}/analysis.txt}"
SYMBOLS_CACHE="${FILES_DIR}/symbols"
USER_SYMBOLS="/symbols-user"
STATUS_FILE="${FILES_DIR}/status.json"
PROV_FILE="${FILES_DIR}/provenance.txt"
TRIAGE_TMP="${FILES_DIR}/.triage.tmp"
RAW_TMP="${FILES_DIR}/.analysis_raw.tmp"
LOWFI_TMP="${FILES_DIR}/.lowfi.tmp"

# Max wrapped-inner-exception expansion passes (see § 6b). Operator-tunable
# via Dockerfile ARG→ENV. A malformed value degrades to the default rather
# than failing the build, consistent with this script's failure-tolerance.
INNER_EXCEPTION_DEPTH="${INNER_EXCEPTION_DEPTH:-9}"
case "${INNER_EXCEPTION_DEPTH}" in ''|*[!0-9]*) INNER_EXCEPTION_DEPTH=9 ;; esac

mkdir -p "${FILES_DIR}" "${SYMBOLS_CACHE}" "${USER_SYMBOLS}"

# ── helpers ──────────────────────────────────────────────────────────────────
# Generic helpers (banner/warn/write_status/soft_fail) + the
# assembly/finalize/render building blocks live in the shared, sourced
# library — also used by trace/analyze-trace.sh. Baked into the base image
# at /opt/lib/analyze-common.sh. Bodies are byte-identical to the former
# inline definitions; the parity GOLDEN gate proves sos output unchanged.
source /opt/lib/analyze-common.sh

# ── 1. Dump file exists? ─────────────────────────────────────────────────────

banner "Step 1/6 — Dump file check"

[ -f "${CASE_DUMP}" ] || soft_fail "Dump not found: ${CASE_DUMP}"

DUMP_SIZE=$(stat -c%s "${CASE_DUMP}" 2>/dev/null || echo "0")
echo "Dump   : ${CASE_DUMP}"
echo "Size   : ${DUMP_SIZE} bytes"

# ── 2. Architecture detection & guard ────────────────────────────────────────

banner "Step 2/6 — Architecture detection & guard"

CONTAINER_ARCH=$(uname -m)    # x86_64 or aarch64
FILE_OUT=$(file "${CASE_DUMP}" 2>/dev/null || echo "")
echo "file(1): ${FILE_OUT}"

if echo "${FILE_OUT}" | grep -q "x86-64"; then
    DUMP_ARCH_DETECTED="x86_64"
elif echo "${FILE_OUT}" | grep -q "aarch64\|ARM aarch64"; then
    DUMP_ARCH_DETECTED="aarch64"
else
    EU_OUT=$(eu-unstrip -n --core "${CASE_DUMP}" 2>/dev/null | head -5 || echo "")
    if echo "${EU_OUT}" | grep -q "x86_64\|x86-64"; then
        DUMP_ARCH_DETECTED="x86_64"
    elif echo "${EU_OUT}" | grep -q "aarch64"; then
        DUMP_ARCH_DETECTED="aarch64"
    else
        DUMP_ARCH_DETECTED="unknown"
        warn "Could not determine dump architecture from ELF headers."
    fi
fi

echo "Dump arch      : ${DUMP_ARCH_DETECTED}"
echo "Container arch : ${CONTAINER_ARCH}"

ARCH_MATCH=false
if [ "${DUMP_ARCH_DETECTED}" != "unknown" ] && \
   [ "${DUMP_ARCH_DETECTED}" != "${CONTAINER_ARCH}" ]; then

    SUGGESTED_ARG="amd64"
    [ "${DUMP_ARCH_DETECTED}" = "aarch64" ] && SUGGESTED_ARG="arm64"

    {
        banner "⚠  ARCHITECTURE MISMATCH — ANALYSIS ABORTED"
        echo "  Dump is    : ${DUMP_ARCH_DETECTED}"
        echo "  Container  : ${CONTAINER_ARCH}"
        echo ""
        echo "  SOS/DAC cannot cross-analyze different architectures."
        echo ""
        echo "  Fix — rebuild with the correct platform:"
        echo "    docker compose build --build-arg DUMP_ARCH=${SUGGESTED_ARG}"
        echo "    ./build.sh --build-arg DUMP_ARCH=${SUGGESTED_ARG}"
        echo ""
        echo "  The container starts for inspection, but dotnet-dump/lldb"
        echo "  cannot load the DAC for a mismatched dump."
    } | tee "${CASE_OUTPUT}"

    write_status "failed"
    exit 0
fi

ARCH_MATCH=true
echo "Architecture   : OK (${CONTAINER_ARCH})"

# ── 3. Runtime version detection ─────────────────────────────────────────────

banner "Step 3/6 — Runtime version detection"

RUNTIME_VERSION="unknown"

# Method A: elfutils eu-unstrip — reads the core's module notes directly, no
# DAC and no executable needed. (Bare `lldb -c <dump>` does NOT work here: it
# reports "no associated executable images" for createdump cores — see Step 4
# / delve-lldb in RUNBOOK.md.)
EU_RT=$(eu-unstrip -n --core "${CASE_DUMP}" 2>/dev/null \
    | grep -o 'Microsoft\.NETCore\.App/[0-9][^/ ]*' | head -1 || echo "")
if [ -n "${EU_RT}" ]; then
    RUNTIME_VERSION=$(echo "${EU_RT}" | cut -d/ -f2)
    echo "Runtime (eu-unstrip)       : ${RUNTIME_VERSION}"
fi

# Method B: strings scan (last resort)
if [ "${RUNTIME_VERSION}" = "unknown" ]; then
    S_VER=$(strings -a "${CASE_DUMP}" 2>/dev/null \
        | grep -oE "Microsoft\.NETCore\.App/[0-9]+\.[0-9]+\.[0-9]+" \
        | head -1 | cut -d/ -f2 || echo "")
    if [ -n "${S_VER}" ]; then
        RUNTIME_VERSION="${S_VER}"
        echo "Runtime (strings scan)     : ${RUNTIME_VERSION}"
    fi
fi

[ "${RUNTIME_VERSION}" = "unknown" ] && \
    warn "Runtime version unknown — dotnet-symbol will still use build-ID matching."

# Fidelity estimate
if [ "${DUMP_SIZE}" -lt 1048576 ]; then
    DUMP_FIDELITY="likely-mini"
    warn "Very small dump (${DUMP_SIZE} B). Likely a mini dump — managed heap may be absent."
    warn "Re-capture: DOTNET_DbgMiniDumpType=4  or  createdump --full <pid>"
else
    DUMP_FIDELITY="full-or-triage"
fi

# ── 4. Provenance record ──────────────────────────────────────────────────────

banner "Step 4/6 — Provenance"

DUMP_SHA256=$(sha256sum "${CASE_DUMP}" 2>/dev/null | awk '{print $1}' || echo "unknown")
BUILD_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DN_VER=$(dotnet --version 2>/dev/null || echo "unknown")
DD_VER=$(dotnet-dump --version 2>/dev/null || echo "unknown")
# dotnet-symbol has no --version flag; read it from the tool manifest instead.
DS_VER=$(dotnet tool list --tool-path /opt/bin 2>/dev/null | awk '/dotnet-symbol/{print $2}')
[ -z "${DS_VER}" ] && DS_VER="unknown"
DSOS_VER=$(dotnet-sos --version 2>/dev/null || echo "unknown")
# dotnet-monitor is the one pinned tool — record its exact version.
DMON_VER=$(dotnet tool list --tool-path /opt/bin 2>/dev/null | awk '/dotnet-monitor/{print $2}')
[ -z "${DMON_VER}" ] && DMON_VER="unknown"

cat > "${PROV_FILE}" << PROVEOF
# Provenance — dotnet-autopsy/sos analysis image
# Re-pin any value via --build-arg to reproduce this exact environment.
# Generated: ${BUILD_TS}

report_tool      : dotnet-dump
base_image_tag   : ${DOTNET_SDK_IMAGE:-unknown}
dotnet_sdk       : ${DN_VER}
dotnet-dump      : ${DD_VER}
dotnet-symbol    : ${DS_VER}
dotnet-sos       : ${DSOS_VER}
dotnet-monitor   : ${DMON_VER}  (pinned)
dump_sha256      : ${DUMP_SHA256}
dump_arch        : ${DUMP_ARCH_DETECTED}
runtime_version  : ${RUNTIME_VERSION}
dump_fidelity    : ${DUMP_FIDELITY}
build_timestamp  : ${BUILD_TS}
PROVEOF

cat "${PROV_FILE}"

# ── 5. Symbol / DAC fetch ─────────────────────────────────────────────────────

banner "Step 5/6 — Symbol & DAC download"

CACHED_SO=$(find "${SYMBOLS_CACHE}" -name "*.so" 2>/dev/null | wc -l)
if [ "${CACHED_SO}" -gt 0 ]; then
    echo "Cache pre-seeded (${CACHED_SO} .so files) — skipping remote fetch (air-gapped mode)."
    DAC_SOURCE="pre-seeded-cache"
else
    DAC_SOURCE="microsoft_symbol_server"
    echo "Fetching DAC+symbols from Microsoft symbol server (matched by build-ID)..."
    SYM_OK=false
    for attempt in 1 2 3; do
        if dotnet-symbol \
                --microsoft-symbol-server \
                --host-only \
                --debugging \
                "${CASE_DUMP}" \
                --symbols \
                --modules \
                --cache-directory "${SYMBOLS_CACHE}" 2>&1; then
            SYM_OK=true
            break
        fi
        warn "dotnet-symbol attempt ${attempt}/3 failed."
        [ "${attempt}" -lt 3 ] && sleep $((attempt * 10))
    done
    if [ "${SYM_OK}" = false ]; then
        warn "dotnet-symbol could not fetch all symbols. Analysis may be partial."
        warn "Non-Microsoft runtime? Supply the DAC in ./symbols/ and rebuild."
        DAC_SOURCE="fetch-failed"
    else
        echo "Symbol fetch complete."
    fi
fi

# ── 6. dotnet-dump analysis ───────────────────────────────────────────────────

banner "Step 6/6 — dotnet-dump analysis"

# Defense-in-depth (the Dockerfile no longer sets this globally): never let
# dotnet-dump's own crash on a bad dump write a multi-GB minidump into the
# image layer.
export DOTNET_DbgEnableMiniDump=0

(dotnet-dump analyze "${CASE_DUMP}" \
    -c "setsymbolserver -ms -cache ${SYMBOLS_CACHE}" \
    -c "setsymbolserver -directory ${USER_SYMBOLS}" \
    -c "runtimes" \
    -c "clrmodules" \
    -c "clrthreads" \
    -c "parallelstacks" \
    -c "clrstack -all" \
    -c "printexception -nested" \
    -c "finalizequeue" \
    -c "threadpool" \
    -c "syncblk" \
    -c "eeheap -gc" \
    -c "dumpheap -stat" \
    -c "analyzeoom" \
    -c "exit" \
    2>&1 || true) > "${RAW_TMP}"

echo "Raw SOS output: $(wc -l < "${RAW_TMP}") lines"

# Judge analysis health from the RAW SOS output ONLY. The assembled
# analysis.txt embeds triage-summary boilerplate whose section headers
# literally contain "clrthreads"/"runtimes"; grepping the assembled file
# self-matches and falsely reports "success" even when SOS produced nothing.
ANALYSIS_BROKEN=false
FAIL_REASON=""
if grep -qE "Failed to find runtime module \(libcoreclr" "${RAW_TMP}" 2>/dev/null; then
    ANALYSIS_BROKEN=true
    FAIL_REASON="SOS could not find the CLR (libcoreclr.so) inside the dump."
elif grep -qE "Can not load or initialize libmscordaccore" "${RAW_TMP}" 2>/dev/null; then
    ANALYSIS_BROKEN=true
    FAIL_REASON="The DAC (libmscordaccore.so) did not match or failed to load."
elif grep -qE "Microsoft\.Diagnostics\.Runtime.*ReadVirtual|Unhandled exception\. System\." "${RAW_TMP}" 2>/dev/null; then
    ANALYSIS_BROKEN=true
    FAIL_REASON="dotnet-dump itself crashed reading the dump (ClrMD ReadVirtual)."
fi

# Positive signal: genuine SOS rows, NOT triage-summary headers.
HAS_REAL_SOS=false
if grep -qE "OS Thread Id:|Lock +Count|^Loaded runtimes|DAC table|Statistics:|^Total [0-9]+ objects" "${RAW_TMP}" 2>/dev/null; then
    HAS_REAL_SOS=true
fi

ERR_COUNT=$(grep -oE "UNKNOWN|Unable to load|Failed to|Error reading" "${RAW_TMP}" 2>/dev/null | wc -l | tr -d ' ')
ERR_COUNT=${ERR_COUNT:-0}

if [ "${ANALYSIS_BROKEN}" = true ]; then
    DUMP_FIDELITY="degraded"
elif [ "${HAS_REAL_SOS}" = false ] || [ "${ERR_COUNT}" -gt 10 ]; then
    warn "Sparse/erroneous SOS output (errors=${ERR_COUNT}, real_sos=${HAS_REAL_SOS})."
    DUMP_FIDELITY="degraded"
fi
sed -i "s/^dump_fidelity.*/dump_fidelity    : ${DUMP_FIDELITY}/" "${PROV_FILE}" 2>/dev/null || true

# Actionable banner placed at the very top of analysis.txt when unusable.
: > "${LOWFI_TMP}"
if [ "${ANALYSIS_BROKEN}" = true ]; then
    warn "${FAIL_REASON}"
    {
        echo "════════════════════════════════════════════════════════════"
        echo "  ⚠  ANALYSIS DEGRADED — DUMP IS LOW-FIDELITY / UNUSABLE"
        echo "════════════════════════════════════════════════════════════"
        echo "  ${FAIL_REASON}"
        echo ""
        echo "  The DAC matched the runtime (${RUNTIME_VERSION}) and arch"
        echo "  (${DUMP_ARCH_DETECTED}) — the DUMP itself lacks the managed"
        echo "  runtime memory SOS needs. Typically a MINI/TRIAGE dump, or"
        echo "  one captured with gdb/gcore."
        echo ""
        echo "  Re-capture a FULL dump at the origin, then rebuild:"
        echo "    DOTNET_DbgEnableMiniDump=1 DOTNET_DbgMiniDumpType=4 <app>"
        echo "    createdump --full <pid> -o /tmp/core.dump"
        echo "    dotnet-dump collect -p <pid> --type Full"
        echo ""
        echo "  See RUNBOOK.md § Troubleshooting and § Step 0 (dump fidelity)."
        echo "════════════════════════════════════════════════════════════"
        echo ""
    } > "${LOWFI_TMP}"
fi

# ── 6b. Expand wrapped inner exceptions ───────────────────────────────────────
# FailFast / AggregateException / rethrow wrap the *real* cause as an inner,
# and `printexception -nested` often just prints
# "Use printexception <ADDR> to see more." for it. The inner address is
# dynamic (unknown until the first pass runs), so do up to
# ${INNER_EXCEPTION_DEPTH} targeted follow-up passes — only when an
# unexpanded inner pointer exists, which is exactly when the inner is the
# root cause. Each pass reloads the dump (the slow step); the depth cap
# (default 9, tunable via the INNER_EXCEPTION_DEPTH build arg / env) bounds
# that. Appended to RAW so it lands in both the raw SOS section and the
# triage summary.
if [ "${ANALYSIS_BROKEN}" != true ] && [ "${INNER_EXCEPTION_DEPTH}" -gt 0 ]; then
    SEEN_ADDRS=""
    for ((_depth = 1; _depth <= INNER_EXCEPTION_DEPTH; _depth++)); do
        NEXT_ADDR=""
        while read -r _a; do
            case " ${SEEN_ADDRS} " in *" ${_a} "*) continue ;; esac
            NEXT_ADDR="${_a}"; break
        done < <(grep -oE "Use printexception [0-9A-Fa-f]{4,} to see more" \
                     "${RAW_TMP}" 2>/dev/null \
                 | grep -oE "[0-9A-Fa-f]{4,}")
        [ -z "${NEXT_ADDR}" ] && break
        SEEN_ADDRS="${SEEN_ADDRS} ${NEXT_ADDR}"
        # NOTE: `-nested` is INVALID with an explicit address ("Wrong
        # option: -nested"); it is only valid as `printexception -nested`
        # with no address. Plain `printexception <ADDR>` prints that
        # exception's block and, if it has a further inner, emits its own
        # "Use printexception <NEXT> to see more." — the loop chases that,
        # so recursion is driven here (INNER_EXCEPTION_DEPTH cap), not by
        # -nested.
        echo "Expanding inner exception (level ${_depth}): printexception ${NEXT_ADDR}"
        {
            echo ""
            echo "═══ INNER EXCEPTION DETAIL — level ${_depth} (printexception ${NEXT_ADDR}) ═══"
            dotnet-dump analyze "${CASE_DUMP}" \
                -c "printexception ${NEXT_ADDR}" \
                -c "exit" 2>&1 || true
        } >> "${RAW_TMP}"
    done
fi

# ── Triage summary ────────────────────────────────────────────────────────────

/opt/report-bin/triage_summary/triage_summary \
    "${RAW_TMP}" "${RUNTIME_VERSION}" "${DUMP_ARCH_DETECTED}" \
    "${DUMP_FIDELITY}" "${DAC_SOURCE}" "${BUILD_TS}" \
    > "${TRIAGE_TMP}" 2>/dev/null \
    || { warn "Triage summary failed — raw output still available."; echo "(triage summary unavailable)" > "${TRIAGE_TMP}"; }

# ── Assemble + status + render (shared building blocks) ───────────────────────
# assemble_output : { prov; ""; lowfi; triage; ""; raw } > CASE_OUTPUT (+rm tmps)
# finalize_status : ANALYSIS_BROKEN/HAS_REAL_SOS/DUMP_FIDELITY → status.json
# render_md_and_banner : analysis.md (best-effort) + closing banner
# All byte-identical to the former inline blocks (see analyze-common.sh).
assemble_output
finalize_status
render_md_and_banner

exit 0
