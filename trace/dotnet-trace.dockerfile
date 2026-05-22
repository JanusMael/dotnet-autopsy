# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# trace/dotnet-trace.dockerfile — dotnet-autopsy/trace : per-case `.nettrace`
# perf-analysis image. Thin case layer on top of the shared dotnet-autopsy-base.
#
# Build (context = REPO ROOT so COPY can reach common/ + trace/ + the trace
#        file; the shared base must be built first):
#   docker build -f common/base.dockerfile      -t dotnet-autopsy-base .
#   docker build -f trace/dotnet-trace.dockerfile -t dotnet-autopsy-trace \
#       --build-arg TRACE_FILE=trace.nettrace .
#   (or: docker compose build trace ; ./build.sh trace ; ./demo.sh trace —
#   all orchestrate this once the wrappers gain a per-image arg, B.13.)
#
# Required build inputs (repo root): the .nettrace capture (TRACE_FILE).
#
# Key build args:
#   TRACE_FILE  — trace filename (default: trace.nettrace)
#   DUMP_ARCH   — informational; traces are not DAC-gated, so this is just
#                 the image platform label (amd64 default).
#   SMOKE_TEST  — set to 1 to run the in-image trace smoke at build time
# ─────────────────────────────────────────────────────────────────────────────

ARG DUMP_ARCH=amd64
ARG TRACE_FILE=trace.nettrace
ARG SMOKE_TEST=0

FROM dotnet-autopsy-base AS analysis

# Re-declare ARGs after FROM (Docker scope rule)
ARG TRACE_FILE=trace.nettrace
ARG DUMP_ARCH=amd64
ARG SMOKE_TEST=0

ENV CASE_TRACE=/analysis/${TRACE_FILE}

# ── Trace-specific scripts + the trace triage project ────────────────────────
# Phase E (v1.1) migrated trace_triage.cs → trace/TraceTriage/ (a real
# .csproj with a Microsoft.Diagnostics.Tracing.TraceEvent NuGet — the only
# report-app NuGet dependency in the family; sos stays BCL-only file-based).
COPY trace/analyze-trace.sh /opt/
COPY trace/TraceTriage/ /opt/TraceTriage/
RUN chmod +x /opt/analyze-trace.sh

# ── Publish the trace triage project ──────────────────────────────────────────
# Same NativeAOT-off + framework-dependent + pristine-stdout discipline as
# the base publish step. The NuGet restore for TraceEvent happens here at
# image build time (needs network — see RUNBOOK "Extending the report
# tools"). Apphost path /opt/report-bin/trace_triage/trace_triage (project
# AssemblyName=trace_triage so the path stays stable across the migration).
RUN export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
    && dotnet publish /opt/TraceTriage/TraceTriage.csproj -c Release -o /opt/report-bin/trace_triage \
           -p:PublishAot=false -p:PublishSingleFile=false --self-contained false \
           > /tmp/pub-trace-triage.log 2>&1 \
       || { echo "ERROR: publish trace_triage failed"; cat /tmp/pub-trace-triage.log; exit 1; } \
    && rm -f /tmp/pub-trace-triage.log \
    && echo "Trace triage project published to /opt/report-bin/trace_triage"

# Reusable-sources: add the trace triage project next to the shared apps +
# README the base already baked into /analysis/sources/.
COPY trace/TraceTriage/ /analysis/sources/TraceTriage/

# ── Optional end-to-end smoke (SMOKE_TEST=1 only) ─────────────────────────────
# Generates a tiny .NET CPU/alloc workload + `dotnet-trace collect` inside the
# image and runs the trace-analysis chain against the resulting capture (the
# trace-specific chain test; the shared toolchain smoke is in the base). Off
# by default. Used by the rot-check CI workflow. Mirrors the sos SMOKE_TEST
# block; uses the BuildKit quoted-heredoc RUN form.
ENV SMOKE_TEST=${SMOKE_TEST}
RUN <<'SMOKE_EOF'
set -u
if [ "${SMOKE_TEST}" != "1" ]; then
    echo "SMOKE_TEST=${SMOKE_TEST} — skipping in-image trace smoke."
    exit 0
fi
set -e
echo "=== SMOKE_TEST=1: Trace end-to-end chain test ==="
SDK_MAJOR=$(dotnet --version | cut -d. -f1)
mkdir -p /tmp/smokeapp/perfapp
cat > /tmp/smokeapp/perfapp/perfapp.csproj <<CSPROJ
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net${SDK_MAJOR}.0</TargetFramework>
  </PropertyGroup>
</Project>
CSPROJ
cat > /tmp/smokeapp/perfapp/Program.cs <<'CS'
// Smoke workload — multiple distinct named methods so the top-CPU report
// has more than one application-level hotspot to rank (matches demo.sh
// and trace/smoke.sh). Kept ASCII-only; ~3 s wall.
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
cd /tmp/smokeapp/perfapp
dotnet build -c Release -o bin >/dev/null
dotnet-trace collect --format nettrace -o /tmp/smoke.nettrace -- /tmp/smokeapp/perfapp/bin/perfapp 2>/dev/null || true
[ -s /tmp/smoke.nettrace ] || { echo "ERROR: smoke nettrace not created"; exit 1; }
echo "Smoke nettrace created: $(stat -c%s /tmp/smoke.nettrace) bytes"
dotnet-trace report /tmp/smoke.nettrace topN -n 5 || { echo "ERROR: report failed"; exit 1; }
echo "=== SMOKE_TEST: Trace end-to-end chain PASSED ==="
rm -rf /tmp/smokeapp /tmp/smoke.nettrace
SMOKE_EOF

# ── Case inputs + docs/sources baking ─────────────────────────────────────────
# Create dirs; ENV vars already set from the base.
RUN mkdir -p /symbols-user

# Bake the project docs + build/run sources UNDER /analysis so the file
# server (root=/analysis) serves them. .md is rendered; sources are text.
# DISTINCT from /analysis/sources/ (the standalone-reusable apps).
RUN mkdir -p /analysis/docs /analysis/docker
COPY README.md trace/RUNBOOK.md /analysis/docs/
COPY common/base.dockerfile trace/dotnet-trace.dockerfile docker-compose.yml .dockerignore \
     trace/analyze-trace.sh common/entrypoint.sh trace/TraceTriage/Program.cs trace/TraceTriage/TraceTriage.csproj common/analysis_md.cs \
     common/json-get.cs build.sh build.ps1 \
     trace/smoke.sh demo.sh \
     /analysis/docker/

COPY ${TRACE_FILE} /analysis/${TRACE_FILE}

# Write MOTD for interactive sessions
RUN cat > /analysis/.motd << 'MOTD'

══════════════════════════════════════════════════════════════════════════
  dotnet-autopsy · trace  ·  .NET CPU/perf trace  ·  post-mortem perf
══════════════════════════════════════════════════════════════════════════

  Welcome. This self-contained container already analyzed the baked
  .nettrace at build time — top CPU functions, basic trace metadata,
  heuristic flags. No prior dotnet-trace knowledge is needed to read the
  results; the interactive tools below take you deeper when you want.

  YOUR ANALYSIS IS READY        (URLs are clickable in most terminals)
  ──────────────────────
    Rendered report : http://localhost:5550/analysis/analysis.md   ← start
    Raw output      : http://localhost:5550/analysis/analysis.txt
                      path /analysis/analysis.txt — authoritative source
    Speedscope JSON : http://localhost:5550/analysis/trace.speedscope.json
                      open in https://www.speedscope.app/ (flame graph)
    Machine status  : http://localhost:5550/analysis/status.json
                      path /analysis/status.json — success|partial|failed
    Hand-off guide  : http://localhost:5550/analysis/docs/RUNBOOK.md
                      (rendered; raw docs/sources under /analysis/docker/)
    Reusable apps   : http://localhost:5550/analysis/sources/
                      the standalone .NET 10 report apps + how to reuse them
    File server     : http://localhost:5550/          browse everything
    Re-show this    : cat /analysis/.motd

  INTERACTIVE ANALYSIS  —  start here
  ───────────────────────────────────
    dotnet-trace report $CASE_TRACE topN -n 25
                 — re-run the top-N analysis with a different N.
    dotnet-trace convert $CASE_TRACE --format speedscope -o /tmp/t
                 — produces /tmp/t.speedscope.json for speedscope.app.
                   (NOTE: -o is a BASENAME; .speedscope.json is appended.)

    NOTE: GC / alloc / contention / thread-pool starvation depth is NOT
    yet in the v1 triage (BCL-first scope; TraceEvent enrichment is the
    planned v1.1). The raw `dotnet-trace report` text below is your
    starting point; for deeper analysis open the speedscope JSON above.

  USEFUL dotnet-trace commands   (general)
  ────────────────────────────────────────
    dotnet-trace collect -- <cmd>      run+trace a command until it exits
    dotnet-trace collect -p <pid>      attach to a running process
    dotnet-trace report <file> topN    top-N methods (cumulative)
    dotnet-trace convert <file> --format speedscope -o <BASE>
                                       speedscope-app folded-stack JSON

  WHAT'S INSTALLED   (all on PATH, in every shell)
  ────────────────────────────────────────────────
    .NET / SDK  dotnet (full SDK — build & repro), dotnet-trace,
                dotnet-counters, dotnet-gcdump, dotnet-stack, dotnet-dump,
                dotnet-sos, dotnet-symbol, dotnet-monitor (installed)
    Native/ELF  lldb, gdb, eu-unstrip, eu-readelf, eu-stack, addr2line,
                objdump, nm, readelf, strings, file
    Scripting   pwsh  — PowerShell 7 (automate triage, parse analysis.txt)
    Editor      fresh — full terminal editor   ·   nano — minimal fallback
    Monitor     btop  ·  top  ·  ps

  WHERE THINGS LIVE
  ─────────────────
    /analysis/         the trace, analysis.md / .txt, status.json
    /analysis/docs/    README.md, RUNBOOK.md  (rendered by the file server)
    /analysis/docker/  the Dockerfiles + build/run scripts that built this
    /analysis/sources/ the standalone-reusable .NET 10 report apps
    $CASE_TRACE        env var → the baked .nettrace

  New here?  Open the rendered report URL above and read the TOP CPU
             FUNCTIONS section.  That's it.
══════════════════════════════════════════════════════════════════════════

MOTD

# Run trace analysis at build time
# Provenance + dotnet-trace report/convert + triage summary all in analyze-trace.sh
RUN /opt/analyze-trace.sh

EXPOSE 5550
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD curl -fL http://localhost:5550/ || exit 1

ENTRYPOINT ["/bin/bash", "/opt/entrypoint.sh"]
