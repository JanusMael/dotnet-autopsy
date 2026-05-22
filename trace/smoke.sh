#!/bin/bash
# trace/smoke.sh — host-side end-to-end smoke for dotnet-autopsy · trace.
#
# Thin per-image caller of common/lib/smoke-common.sh. The only trace-specific
# bits are the two hooks: make_synthetic_input (a throwaway `.nettrace`
# generated in a disposable SDK container with dotnet-trace tool-installed,
# so a fresh clone needs no real trace) and content_asserts (the TOP CPU
# FUNCTIONS section in analysis.txt proving the trace chain wrote a real
# triage). Everything else (base+image build, run, HTTP, pwsh, status,
# cleanup) is the shared skeleton.
#
# Usage:  ./trace/smoke.sh [extra docker build args…]   (or: ./smoke.sh trace)

set -euo pipefail

. "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/../common/lib/smoke-common.sh"

# ── Hook: generate a throwaway .nettrace from a tiny CPU/alloc workload ─────
# Runs the workload + `dotnet-trace collect` in a disposable SDK container.
# dotnet-trace is tool-installed inside the gen container so this works even
# on a fresh clone before dotnet-autopsy-base exists locally. Trace lands at
# the REPO ROOT because the build context is the repo root and the trace
# Dockerfile does `COPY ${TRACE_FILE} …`.
make_synthetic_input() {
    SMOKE_INPUT_NAME="smoke-trace.nettrace"
    SMOKE_INPUT_PATH="${ROOT_DIR}/${SMOKE_INPUT_NAME}"
    SMOKE_INPUT_BUILDARG="TRACE_FILE"

    echo "Step — Generating throwaway .nettrace (linux/${DUMP_ARCH})..."
    rm -f "${SMOKE_INPUT_PATH}"
    docker rm -f "${GEN_NAME}" 2>/dev/null || true
    docker run --name "${GEN_NAME}" \
        --platform "linux/${DUMP_ARCH}" \
        "${DOTNET_SDK_IMAGE}" \
        bash -c '
            set -e
            export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
            SDK_MAJOR=$(dotnet --version | cut -d. -f1)
            mkdir -p /opt/dt && dotnet tool install dotnet-trace --tool-path /opt/dt >/dev/null
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
            cat > Program.cs <<'CS'
// Smoke workload — multiple distinct named methods so the top-CPU report
// has more than one application-level hotspot to rank (matches demo.sh).
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Threading;
new Thread(BackgroundWorker) { IsBackground = true, Name = "worker-A" }.Start();
var sw = System.Diagnostics.Stopwatch.StartNew();
long total = 0;
while (sw.Elapsed.TotalSeconds < 3)
{
    total += HashRecords(32);
    total += ParseAndSum(1500);
    total += AllocateBuffers(12);
    total += IndexLookup(300);
}
Console.WriteLine("done " + total);
static void BackgroundWorker()
{
    var w = System.Diagnostics.Stopwatch.StartNew();
    while (w.Elapsed.TotalSeconds < 3) Thread.Sleep(25);
}
static long HashRecords(int n)
{
    using var sha = SHA256.Create();
    var buf = new byte[4096];
    long s = 0;
    for (int i = 0; i < n; i++) { var h = sha.ComputeHash(buf); s += h[0]; }
    return s;
}
static long ParseAndSum(int n)
{
    long s = 0;
    for (int i = 0; i < n; i++)
    {
        var str = i.ToString();
        if (int.TryParse(str, out var v)) s += v;
    }
    return s;
}
static long AllocateBuffers(int n)
{
    var lst = new List<byte[]>();
    long s = 0;
    for (int i = 0; i < n; i++) { lst.Add(new byte[8192]); s += lst[i].Length; }
    return s;
}
static long IndexLookup(int n)
{
    var dict = new Dictionary<int, string>();
    for (int i = 0; i < n; i++) dict[i] = "v" + i;
    long s = 0;
    foreach (var k in dict.Keys) s += k;
    return s;
}
CS
            dotnet build -c Release -o bin >/dev/null
            dotnet-trace collect --format nettrace -o /tmp/smoke.nettrace -- /tmp/app/bin/app 2>/dev/null || true
            [ -s /tmp/smoke.nettrace ] || { echo "ERROR: nettrace not created"; exit 1; }
            echo "trace bytes: $(stat -c%s /tmp/smoke.nettrace)"
        '
    docker cp "${GEN_NAME}:/tmp/smoke.nettrace" "${SMOKE_INPUT_PATH}"
    docker rm -f "${GEN_NAME}" >/dev/null 2>&1 || true
    [ -s "${SMOKE_INPUT_PATH}" ] || { echo "ERROR: smoke trace not copied out"; exit 1; }
    echo "Throwaway trace: ${SMOKE_INPUT_PATH} ($(wc -c < "${SMOKE_INPUT_PATH}") bytes)"
    echo ""
    echo "Step — Trace generation PASSED"
}

# ── Hook: trace-specific in-container assertion ─────────────────────────────
# The triage assembled into analysis.txt must contain the TOP CPU FUNCTIONS
# section + at least one parsed row → proves trace_triage.cs ran cleanly.
content_asserts() {
    echo ""
    echo "Step — Trace triage content check (TOP CPU FUNCTIONS present + rows)..."
    docker exec "${CONTAINER_NAME}" bash -c '
        grep -q "TOP CPU FUNCTIONS" /analysis/analysis.txt \
            || { echo "ERROR: TOP CPU FUNCTIONS section missing"; exit 1; }
        # at least one parsed row (trace_triage formats them as " NN. fn  incl=… excl=…")
        grep -qE "^[[:space:]]+[0-9]+\.[[:space:]]+\S.*incl=" /analysis/analysis.txt \
            || { echo "ERROR: no TOP CPU rows parsed"; exit 1; }
        echo "TOP CPU FUNCTIONS section + rows: OK"
    ' || exit 1
    echo ""
    echo "Step — Trace triage content PASSED"
}

# ── Orchestrate ──────────────────────────────────────────────────────────────
sc_init trace
make_synthetic_input
sc_build trace/dotnet-trace.dockerfile "$@"
sc_run_and_wait
sc_http_checks
content_asserts
sc_pwsh_check
sc_status_check
sc_done
