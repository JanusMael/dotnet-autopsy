#!/bin/bash
# entrypoint.sh — container startup script.
# Prints analysis status/output, then exec's the file server (so signals work).

FILES_DIR="${FILES_DIR:-/analysis}"
FILE_SERVER_DIR="${FILE_SERVER_DIR:-/fileserver}"
STATUS_FILE="${FILES_DIR}/status.json"
CASE_OUTPUT="${CASE_OUTPUT:-${FILES_DIR}/analysis.txt}"
FILE_SERVER_EXE="${FILE_SERVER_DIR}/Bennewitz.Ninja.FileServer"

# ── Status banner ─────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           dotnet-autopsy  analysis  container            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

if [ -f "${STATUS_FILE}" ]; then
    STATUS=$(json-get "${STATUS_FILE}" status 2>/dev/null || echo "unknown")
    RUNTIME=$(json-get "${STATUS_FILE}" runtime_version 2>/dev/null || echo "unknown")
    FIDELITY=$(json-get "${STATUS_FILE}" dump_fidelity 2>/dev/null || echo "unknown")
    echo "  Analysis status  : ${STATUS}"
    echo "  Runtime version  : ${RUNTIME}"
    echo "  Dump fidelity    : ${FIDELITY}"
else
    echo "  Analysis status  : (status.json not found)"
fi

SYM_DIR="${SYMBOLS_CACHE:-${FILES_DIR}/symbols}"
if [ -d "${SYM_DIR}" ]; then
    SYM_N=$(find "${SYM_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')
    SYM_SZ=$(du -sh "${SYM_DIR}" 2>/dev/null | cut -f1)
    echo "  Symbol cache     : ${SYM_N} files, ${SYM_SZ:-?}  (details: dsos-info)"
fi

echo ""
echo "  Rendered report  : http://localhost:5550/analysis/analysis.md  (friendly)"
echo "  Raw analysis     : ${CASE_OUTPUT}  (authoritative; ?raw=1 for md source)"
echo "  Browse results   : http://localhost:5550/"
echo "  Interactive shell: docker exec -it <container> bash"
echo "  Quick analysis   : docker exec -it <container> delve       (dotnet-dump)"
echo "                     docker exec -it <container> delve-lldb  (lldb + SOS)"
echo ""
echo "──────────────────────────────────────────────────────────"
echo ""

# Print the triage summary portion of the analysis (first ~80 lines)
if [ -f "${CASE_OUTPUT}" ]; then
    head -80 "${CASE_OUTPUT}"
    LINE_COUNT=$(wc -l < "${CASE_OUTPUT}")
    if [ "${LINE_COUNT}" -gt 80 ]; then
        echo ""
        echo "  ... (${LINE_COUNT} total lines — browse the full output at http://localhost:5550/)"
    fi
else
    echo "  (analysis output not found — analysis may have failed)"
fi

echo ""
echo "──────────────────────────────────────────────────────────"
echo ""

# ── Start file server ─────────────────────────────────────────────────────────

echo "Starting file server: ${FILE_SERVER_EXE}"
echo ""

exec "${FILE_SERVER_EXE}" \
    --root "${FILES_DIR}" \
    --route "analysis" \
    --http-port 5550
