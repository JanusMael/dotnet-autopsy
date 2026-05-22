#!/bin/bash
# common/lib/analyze-common.sh — shared, SOURCED library for the
# dotnet-autopsy per-image analyze scripts (sos/analyze.sh,
# trace/analyze-trace.sh). Defines the generic helpers + the
# assembly / final-status / render+banner building blocks.
#
# NO top-level execution — this file only defines functions. The bodies
# are byte-for-byte identical to the former inline analyze.sh logic; the
# parity GOLDEN gate proves the sos output is unchanged by the extraction.
#
# Baked into the shared base image at /opt/lib/analyze-common.sh and
# `source`d by /opt/analyze.sh (build time). The sourcing script MUST have
# already set: FILES_DIR CASE_OUTPUT STATUS_FILE PROV_FILE TRIAGE_TMP
# RAW_TMP LOWFI_TMP CASE_DUMP, and for write_status also
# DUMP_ARCH_DETECTED CONTAINER_ARCH ARCH_MATCH DUMP_FIDELITY
# RUNTIME_VERSION DAC_SOURCE, and for finalize_status ANALYSIS_BROKEN
# HAS_REAL_SOS DUMP_FIDELITY.

banner() {
    echo ""
    echo "══════════════════════════════════════════════════════"
    printf "  %s\n" "$*"
    echo "══════════════════════════════════════════════════════"
    echo ""
}

warn() { printf "⚠  WARNING: %s\n" "$*"; }

write_status() {
    local s="$1"
    cat > "${STATUS_FILE}" << STATUSEOF
{
  "status": "${s}",
  "dump_file": "${CASE_DUMP}",
  "dump_arch": "${DUMP_ARCH_DETECTED:-unknown}",
  "container_arch": "${CONTAINER_ARCH:-unknown}",
  "arch_match": ${ARCH_MATCH:-false},
  "dump_fidelity": "${DUMP_FIDELITY:-unknown}",
  "runtime_version": "${RUNTIME_VERSION:-unknown}",
  "dac_source": "${DAC_SOURCE:-unknown}",
  "analysis_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
STATUSEOF
}

soft_fail() {
    # Write failure notice but exit 0 — image always builds
    printf "✗  %s\n" "$*"
    {
        echo "ANALYSIS FAILED"
        echo ""
        printf "%s\n" "$*"
        echo ""
        echo "The container will still start. Attach interactively to investigate:"
        echo "  docker exec -it dotnet-autopsy-sos bash"
        echo "  delve   # pre-configured dotnet-dump wrapper"
    } > "${CASE_OUTPUT}"
    write_status "failed"
    exit 0
}

# Assemble the final analysis.txt from the four parts, then drop the temps.
# Byte-identical to the former inline `{ … } > CASE_OUTPUT` block.
assemble_output() {
    {
        cat "${PROV_FILE}"
        echo ""
        cat "${LOWFI_TMP}"
        cat "${TRIAGE_TMP}"
        echo ""
        cat "${RAW_TMP}"
    } > "${CASE_OUTPUT}"

    rm -f "${RAW_TMP}" "${TRIAGE_TMP}" "${LOWFI_TMP}"
}

# Final status — derived from RAW analysis health, never the assembled
# file. Sets FINAL_STATUS and writes status.json. Byte-identical.
finalize_status() {
    if [ "${ANALYSIS_BROKEN}" = true ]; then
        FINAL_STATUS="failed"
    elif [ "${HAS_REAL_SOS}" = true ]; then
        [ "${DUMP_FIDELITY}" = "degraded" ] && FINAL_STATUS="partial" || FINAL_STATUS="success"
    else
        FINAL_STATUS="partial"
    fi

    write_status "${FINAL_STATUS}"
}

# Rendered Markdown view (additive; analysis.txt stays authoritative) +
# the closing "Analysis complete" banner. Best-effort: a render failure
# must NOT fail the build and must leave analysis.txt untouched.
# Byte-identical to the former inline block.
render_md_and_banner() {
    MD_OUT="${FILES_DIR}/analysis.md"
    if /opt/report-bin/analysis_md/analysis_md "${CASE_OUTPUT}" "${STATUS_FILE}" \
            > "${MD_OUT}" 2>/dev/null && [ -s "${MD_OUT}" ]; then
        MD_NOTE="  markdown  : ${MD_OUT}  ($(wc -l < "${MD_OUT}") lines)"
    else
        warn "Markdown render failed — analysis.txt is unaffected."
        rm -f "${MD_OUT}"
        MD_NOTE="  markdown  : (not generated — see warning above)"
    fi

    banner "Analysis complete — status: ${FINAL_STATUS}"
    echo "  output    : ${CASE_OUTPUT}  ($(wc -l < "${CASE_OUTPUT}") lines)"
    echo "${MD_NOTE}"
    echo "  provenance: ${PROV_FILE}"
    echo "  status    : ${STATUS_FILE}"
    echo ""
    echo "Browse results at http://localhost:5550/ once the container starts."
    echo "Rendered report: http://localhost:5550/analysis/analysis.md  (?raw=1 for source)"
}
