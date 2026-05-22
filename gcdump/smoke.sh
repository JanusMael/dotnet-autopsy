#!/bin/bash
# gcdump/smoke.sh — host-side end-to-end smoke for dotnet-autopsy · gcdump.
#
# Thin per-image caller of common/lib/smoke-common.sh. The only gcdump-specific
# bits are the two hooks: make_synthetic_input (a throwaway `.gcdump` generated
# by launching a tiny allocating workload in a disposable SDK container and
# `dotnet-gcdump collect`-ing it) and content_asserts (the TOP TYPES BY SIZE
# section + at least one parsed row, proving gcdump_triage.cs ran cleanly).
#
# Usage:  ./gcdump/smoke.sh [extra docker build args…]   (or: ./smoke.sh gcdump)

set -euo pipefail

. "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/../common/lib/smoke-common.sh"

# ── Hook: generate a throwaway .gcdump from a tiny allocating workload ──────
# Runs the workload in the background, dotnet-gcdump collects from its pid,
# then kills the workload. dotnet-gcdump is tool-installed inside the gen
# container so this works on a fresh clone before dotnet-autopsy-base exists
# locally. Gcdump lands at the REPO ROOT because the build context is the
# repo root and the gcdump Dockerfile does `COPY ${GCDUMP_FILE} …`.
make_synthetic_input() {
    SMOKE_INPUT_NAME="smoke-heap.gcdump"
    SMOKE_INPUT_PATH="${ROOT_DIR}/${SMOKE_INPUT_NAME}"
    SMOKE_INPUT_BUILDARG="GCDUMP_FILE"

    echo "Step — Generating throwaway .gcdump (linux/${DUMP_ARCH})..."
    rm -f "${SMOKE_INPUT_PATH}"
    docker rm -f "${GEN_NAME}" 2>/dev/null || true
    docker run --name "${GEN_NAME}" \
        --platform "linux/${DUMP_ARCH}" \
        "${DOTNET_SDK_IMAGE}" \
        bash -c '
            set -e
            export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
            SDK_MAJOR=$(dotnet --version | cut -d. -f1)
            mkdir -p /opt/dt && dotnet tool install dotnet-gcdump --tool-path /opt/dt >/dev/null
            export PATH="/opt/dt:${PATH}"
            mkdir -p /tmp/app && cd /tmp/app
            cat > app.csproj <<CSPROJ
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net${SDK_MAJOR}.0</TargetFramework>
  </PropertyGroup>
</Project>
CSPROJ
            cat > Program.cs <<\CS
// Smoke workload — allocate distinct type shapes (strings, byte buffers,
// dictionary entries) then idle so dotnet-gcdump collect can attach and
// snapshot. Matches demo.sh / dockerfile SMOKE_TEST block.
//
// Static fields (declared AFTER the top-level statements, per C# top-
// level program rules) keep the collections rooted across Thread.Sleep
// — JIT register-pressure analysis can otherwise eliminate Main-local
// refs after their last read, GC frees them, and dotnet-gcdump captures
// a startup-only heap instead of the actual workload heap.
//
// NB: no C-sharp dollar-interp here and no dollar-curly-anything. The
// outer bash wrapper (single-quoted bash -c) effectively unquotes the
// heredoc delimiter, re-enabling shell expansion in the body.
using System.Collections.Generic;
using System.Threading;
for (int i = 0; i < 5000; i++)
{
    Roots.Strs.Add("hello_" + i);
    Roots.Bufs.Add(new byte[4096]);
    Roots.Map[i] = "value_" + i;
}
System.Console.WriteLine("heapapp ready strs=" + Roots.Strs.Count
    + " bufs=" + Roots.Bufs.Count
    + " map="  + Roots.Map.Count);
Thread.Sleep(30000);

static class Roots
{
    public static List<string>            Strs = new();
    public static List<byte[]>            Bufs = new();
    public static Dictionary<int,string>  Map  = new();
}
CS
            dotnet build -c Release -o bin >/dev/null
            ./bin/app &
            APP_PID=$!
            # 8 s margin for cold-container startup + JIT + alloc loop.
            sleep 8
            dotnet-gcdump collect -p $APP_PID -o /tmp/smoke.gcdump 2>/dev/null || true
            kill -9 $APP_PID 2>/dev/null || true; wait 2>/dev/null || true
            [ -s /tmp/smoke.gcdump ] || { echo "ERROR: gcdump not created"; exit 1; }
            echo "gcdump bytes: $(stat -c%s /tmp/smoke.gcdump)"
        '
    docker cp "${GEN_NAME}:/tmp/smoke.gcdump" "${SMOKE_INPUT_PATH}"
    docker rm -f "${GEN_NAME}" >/dev/null 2>&1 || true
    [ -s "${SMOKE_INPUT_PATH}" ] || { echo "ERROR: smoke gcdump not copied out"; exit 1; }
    echo "Throwaway gcdump: ${SMOKE_INPUT_PATH} ($(wc -c < "${SMOKE_INPUT_PATH}") bytes)"
    echo ""
    echo "Step — Gcdump generation PASSED"
}

# ── Hook: gcdump-specific in-container assertion ────────────────────────────
# The triage assembled into analysis.txt must contain the TOP TYPES BY SIZE
# section + at least one parsed row → proves gcdump_triage.cs ran cleanly.
content_asserts() {
    echo ""
    echo "Step — Gcdump triage content check (TOP TYPES BY SIZE present + rows)..."
    docker exec "${CONTAINER_NAME}" bash -c '
        grep -q "TOP TYPES BY SIZE" /analysis/analysis.txt \
            || { echo "ERROR: TOP TYPES BY SIZE section missing"; exit 1; }
        grep -qE "^[[:space:]]+[0-9]+\.[[:space:]]+\S.*bytes=" /analysis/analysis.txt \
            || { echo "ERROR: no type rows parsed"; exit 1; }
        echo "TOP TYPES BY SIZE section + rows: OK"
    ' || exit 1
    echo ""
    echo "Step — Gcdump triage content PASSED"
}

# ── Orchestrate ──────────────────────────────────────────────────────────────
sc_init gcdump
make_synthetic_input
sc_build gcdump/dotnet-gcdump.dockerfile "$@"
sc_run_and_wait
sc_http_checks
content_asserts
sc_pwsh_check
sc_status_check
sc_done
