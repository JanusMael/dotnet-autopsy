#!/bin/bash
# sos/smoke.sh — host-side end-to-end smoke for dotnet-autopsy · sos.
#
# Thin per-image caller of common/lib/smoke-common.sh. The only sos-specific
# bits are the two hooks: make_synthetic_input (a throwaway Linux .NET core
# dump, generated in a disposable SDK container so a fresh clone needs no
# real dump) and content_asserts (an interactive dotnet-dump session proving
# the SOS chain). Everything else (base+image build, run, HTTP, pwsh, status,
# cleanup) is the shared skeleton. Self-contained, CI-friendly, OS-agnostic.
#
# Usage:  ./sos/smoke.sh [extra docker build args…]   (or: ./smoke.sh sos)

set -euo pipefail

. "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/../common/lib/smoke-common.sh"

# ── Hook: generate a throwaway Linux managed core dump ───────────────────────
# Runs a trivial FailFast app in a disposable SDK container so the dump is a
# real managed Linux core. Copied out via `docker cp` (no bind mounts). The
# dump lands at the REPO ROOT because the build context is the repo root and
# sos/dotnet-sos.dockerfile does `COPY ${DUMP_FILE} …`.
make_synthetic_input() {
    SMOKE_INPUT_NAME="smoke-core.dump"
    SMOKE_INPUT_PATH="${ROOT_DIR}/${SMOKE_INPUT_NAME}"
    SMOKE_INPUT_BUILDARG="DUMP_FILE"

    echo "Step — Generating throwaway crash dump (linux/${DUMP_ARCH})..."
    rm -f "${SMOKE_INPUT_PATH}"
    docker rm -f "${GEN_NAME}" 2>/dev/null || true
    docker run --name "${GEN_NAME}" \
        --platform "linux/${DUMP_ARCH}" \
        "${DOTNET_SDK_IMAGE}" \
        bash -c '
            set -e
            SDK_MAJOR=$(dotnet --version | cut -d. -f1)
            mkdir -p /tmp/app && cd /tmp/app
            cat > app.csproj <<CSPROJ
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net${SDK_MAJOR}.0</TargetFramework>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
CSPROJ
            printf "System.Environment.FailFast(\"smoke-test-crash\");\n" > Program.cs
            DOTNET_DbgEnableMiniDump=1 \
                DOTNET_DbgMiniDumpName=/tmp/smoke.dump \
                DOTNET_DbgMiniDumpType=4 \
                dotnet run 2>/dev/null || true
            [ -f /tmp/smoke.dump ] || { echo "ERROR: dump not created"; exit 1; }
            echo "dump bytes: $(stat -c%s /tmp/smoke.dump)"
        '
    docker cp "${GEN_NAME}:/tmp/smoke.dump" "${SMOKE_INPUT_PATH}"
    docker rm -f "${GEN_NAME}" >/dev/null 2>&1 || true
    [ -s "${SMOKE_INPUT_PATH}" ] || { echo "ERROR: smoke dump not copied out"; exit 1; }
    echo "Throwaway dump: ${SMOKE_INPUT_PATH} ($(wc -c < "${SMOKE_INPUT_PATH}") bytes)"
    echo ""
    echo "Step — Dump generation PASSED"
}

# ── Hook: SOS-specific in-container assertion ────────────────────────────────
content_asserts() {
    echo ""
    echo "Step — Interactive dotnet-dump exec check..."
    local case_dump
    case_dump=$(docker exec "${CONTAINER_NAME}" bash -c 'ls /analysis/*.dump 2>/dev/null | head -1')
    [ -n "${case_dump}" ] || { echo "ERROR: No dump in /analysis/ — stage-2 COPY failed."; exit 1; }
    docker exec "${CONTAINER_NAME}" bash -c "
        dotnet-dump analyze '${case_dump}' \
            -c 'runtimes' \
            -c 'clrthreads' \
            -c 'exit' 2>&1 | head -30
    " || { echo "ERROR: dotnet-dump exec failed"; exit 1; }
    echo ""
    echo "Step — dotnet-dump exec PASSED"
}

# ── Orchestrate ──────────────────────────────────────────────────────────────
sc_init sos
make_synthetic_input
sc_build sos/dotnet-sos.dockerfile "$@"
sc_run_and_wait
sc_http_checks
content_asserts
sc_pwsh_check
sc_status_check
sc_done
