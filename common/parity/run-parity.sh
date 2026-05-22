#!/bin/bash
# common/parity/run-parity.sh — the differential parity GATE for the
# dotnet-autopsy .NET report tools.
#
# Shared apps:  common/json-get.cs , common/analysis_md.cs
# Per-image triage app:  sos/triage_summary.cs | trace/TraceTriage/TraceTriage.csproj | gcdump/gcdump_triage.cs
# Per-image corpus:  <image>/parity/fixtures/ + <image>/parity/golden/
#
# These tools are pure deterministic transformers (input + argv -> stdout),
# so equivalence is provable by byte-diff, not judgement.
#
# Modes (auto-detected):
#   ORACLE  — *.py present: run BOTH python3 <oracle> and the .NET binary on
#             every fixture and `cmp` stdout. (Historical; the .py oracle was
#             deleted at sign-off, so this is normally GOLDEN.)
#   GOLDEN  — *.py absent: `cmp` the .NET binary's output against the
#             committed <image>/parity/golden/* captured from the oracle.
#             A real regression gate with NO python dependency.
#
#   bash common/parity/run-parity.sh [sos|trace]                # gate (auto)
#   bash common/parity/run-parity.sh [sos|trace] -k             # skip rebuild
#   bash common/parity/run-parity.sh [sos|trace] --update-golden# ORACLE only
#   bash common/parity/run-parity.sh [sos|trace] --seed-golden  # seed from .cs
#       (no oracle needed; locks the current .cs output as the baseline. Used
#        for images that never had a Python oracle, e.g. trace. Honest
#        regression-only gate — diffs catch any future .cs drift.)
#
# Requires: .NET 10 SDK on PATH (always) + python3 (ORACLE/--update-golden).
# No Docker. PASS == zero byte difference everywhere; exit nonzero on ANY diff.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # repo root
IMAGE="sos"
KEEP=0
UPDATE=0
SEED=0
for a in "$@"; do
    case "${a}" in
        sos|trace|gcdump) IMAGE="${a}" ;;
        -k) KEEP=1 ;;
        --update-golden) UPDATE=1 ;;
        --seed-golden)   SEED=1 ;;
        *) echo "unknown arg: ${a}  (usage: run-parity.sh [sos|trace|gcdump] [-k] [--update-golden|--seed-golden])"; exit 2 ;;
    esac
done
if [ "${UPDATE}" = 1 ] && [ "${SEED}" = 1 ]; then
    echo "ERROR: --update-golden and --seed-golden are mutually exclusive"; exit 2
fi

case "${IMAGE}" in
    sos)    TRIAGE_APP="triage_summary"; TRIAGE_SRC="${ROOT}/sos/triage_summary.cs"; ORACLE_SRC="${ROOT}/sos/triage_summary.py" ;;
    trace)  TRIAGE_APP="trace_triage";   TRIAGE_SRC="${ROOT}/trace/TraceTriage/TraceTriage.csproj"; ORACLE_SRC="" ;;
    gcdump) TRIAGE_APP="gcdump_triage";  TRIAGE_SRC="${ROOT}/gcdump/gcdump_triage.cs"; ORACLE_SRC="" ;;
esac

FX="${ROOT}/${IMAGE}/parity/fixtures"
GOLD="${ROOT}/${IMAGE}/parity/golden"
BIN="${ROOT}/parity/_bin/${IMAGE}"   # repo-root parity/ (gitignored + dockerignored)

fail=0
note() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { note "MISSING: $1 not on PATH"; exit 2; }; }
need dotnet

# ORACLE only if the per-image .py oracle AND the shared analysis_md.py exist
# (deleted at sign-off → GOLDEN). app src -> publish dir pairs:
ORACLE=0
if [ -n "${ORACLE_SRC}" ] && [ -f "${ORACLE_SRC}" ] && [ -f "${ROOT}/common/analysis_md.py" ]; then
    ORACLE=1
fi
if [ "${UPDATE}" = 1 ] && [ "${ORACLE}" = 0 ]; then
    note "--update-golden requires the *.py oracle (none found)"; exit 2
fi
if [ "${ORACLE}" = 1 ]; then need python3; fi
mode="GOLDEN"; [ "${ORACLE}" = 1 ] && mode="ORACLE"
[ "${SEED}" = 1 ] && mode="SEED-GOLDEN"
note "parity mode: ${mode}  image: ${IMAGE}$( [ "${UPDATE}" = 1 ] && echo ' (refreshing goldens from oracle)')$( [ "${SEED}" = 1 ] && echo ' (seeding goldens from .cs output)')"

# ── Build the file-based apps once (offline-capable; pristine stdout) ─────────
if [ "${KEEP}" = 0 ] || [ ! -d "${BIN}" ]; then
    rm -rf "${BIN}"; mkdir -p "${BIN}"
    export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
    # name|src triplets: shared apps from common/, triage app per-image.
    for pair in \
        "json-get|${ROOT}/common/json-get.cs" \
        "analysis_md|${ROOT}/common/analysis_md.cs" \
        "${TRIAGE_APP}|${TRIAGE_SRC}"; do
        app="${pair%%|*}"; src="${pair#*|}"
        # NOTE: `dotnet publish file.cs` implicitly enables NativeAOT in
        # .NET 10 (needs clang/gcc, absent here). Framework-dependent build
        # with AOT/single-file off — same flags as the Dockerfile publish
        # step. See <image>/RUNBOOK.md "Extending the report tools".
        if ! dotnet publish "${src}" -c Release -o "${BIN}/${app}" \
                -p:PublishAot=false -p:PublishSingleFile=false --self-contained false \
                >"${BIN}/${app}.build.log" 2>&1; then
            note "BUILD FAIL: ${app} (${src})"; tail -20 "${BIN}/${app}.build.log"; exit 2
        fi
    done
fi
TRIAGE="${BIN}/${TRIAGE_APP}/${TRIAGE_APP}"
MD="${BIN}/analysis_md/analysis_md"
JG="${BIN}/json-get/json-get"

"${JG}" --selftest >/dev/null 2>&1 || { note "json-get --selftest FAILED"; fail=1; }
mkdir -p "${GOLD}"

diffdump() { diff <(cat -A "$1") <(cat -A "$2") 2>/dev/null | head -40; }

# gate <label> <golden-name> <cs-out-file> [<py-out-file>]
gate() {
    local label="$1" gname="$2" cs="$3" py="${4:-}" g="${GOLD}/$2"
    if [ "${SEED}" = 1 ]; then
        # Capture the .cs output as the baseline golden. Use when there is
        # no oracle (trace) or to re-baseline an intentional behavior change
        # (commit the resulting golden after manual inspection).
        cp "${cs}" "${g}"; note "  SEED  ${label}  ($(wc -c <"${cs}"|tr -d ' ') b → golden)"; return
    fi
    if [ "${UPDATE}" = 1 ]; then
        cp "${py}" "${g}"; note "  GOLD  ${label}  (updated)"; return
    fi
    if [ "${ORACLE}" = 1 ]; then
        if cmp -s "${py}" "${cs}"; then
            note "  PASS  ${label}  ($(wc -c <"${cs}"|tr -d ' ') b, vs oracle)"
        else
            note "  FAIL  ${label}  (py=$(wc -c <"${py}"|tr -d ' ') cs=$(wc -c <"${cs}"|tr -d ' '))"
            diffdump "${py}" "${cs}"; fail=1
        fi
    else
        if [ ! -f "${g}" ]; then
            note "  FAIL  ${label}  (no golden ${gname}; run --update-golden)"; fail=1; return
        fi
        if cmp -s "${g}" "${cs}"; then
            note "  PASS  ${label}  ($(wc -c <"${cs}"|tr -d ' ') b, vs golden)"
        else
            note "  FAIL  ${label}  (golden=$(wc -c <"${g}"|tr -d ' ') cs=$(wc -c <"${cs}"|tr -d ' '))"
            diffdump "${g}" "${cs}"; fail=1
        fi
    fi
}

for d in "${FX}"/*/; do
    name="$(basename "${d}")"
    note "── fixture: ${name}"
    tmp="$(mktemp -d)"

    if [ -f "${d}raw.txt" ] && [ -f "${d}args" ]; then
        mapfile -t A < "${d}args"
        "${TRIAGE}" "${d}raw.txt" "${A[0]}" "${A[1]}" "${A[2]}" "${A[3]}" "${A[4]}" >"${tmp}/t.cs" 2>/dev/null
        if [ "${ORACLE}" = 1 ]; then
            python3 "${ORACLE_SRC}" "${d}raw.txt" "${A[0]}" "${A[1]}" "${A[2]}" "${A[3]}" "${A[4]}" >"${tmp}/t.py" 2>/dev/null
        fi
        gate "triage   ${name}" "${name}.triage" "${tmp}/t.cs" "${tmp}/t.py"
    fi

    if [ -f "${d}analysis.txt" ]; then
        sj=""; [ -f "${d}status.json" ] && sj="${d}status.json"
        "${MD}" "${d}analysis.txt" ${sj:+"${sj}"} >"${tmp}/m.cs" 2>/dev/null
        if [ "${ORACLE}" = 1 ]; then
            python3 "${ROOT}/common/analysis_md.py" "${d}analysis.txt" ${sj:+"${sj}"} >"${tmp}/m.py" 2>/dev/null
        fi
        gate "md       ${name}" "${name}.md" "${tmp}/m.cs" "${tmp}/m.py"
    fi

    if [ -f "${d}status.json" ]; then
        : > "${tmp}/j.cs"; : > "${tmp}/j.py"
        for key in status runtime_version dump_fidelity arch_match __absent__; do
            jv=$( ( "${JG}" "${d}status.json" "${key}" ) 2>/dev/null || echo unknown )
            printf '%s\t%s\n' "${key}" "${jv}" >> "${tmp}/j.cs"
            if [ "${ORACLE}" = 1 ]; then
                pv=$( ( python3 -c "import json; d=json.load(open('${d}status.json')); print(d.get('${key}','unknown'))" ) 2>/dev/null || echo unknown )
                printf '%s\t%s\n' "${key}" "${pv}" >> "${tmp}/j.py"
            fi
        done
        gate "json-get ${name}" "${name}.jsonget" "${tmp}/j.cs" "${tmp}/j.py"
    fi

    rm -rf "${tmp}"
done

note ""
if [ "${UPDATE}" = 1 ]; then
    note "GOLDENS REFRESHED in ${IMAGE}/parity/golden/ (commit them)"
    exit 0
fi
if [ "${SEED}" = 1 ]; then
    note "GOLDENS SEEDED in ${IMAGE}/parity/golden/ (commit them; from now on this is the regression baseline)"
    exit 0
fi
if [ "${fail}" = 0 ]; then
    note "PARITY: ALL FIXTURES BYTE-IDENTICAL (${mode}, ${IMAGE})"
    exit 0
else
    note "PARITY: FAILED — see diffs above"
    exit 1
fi
