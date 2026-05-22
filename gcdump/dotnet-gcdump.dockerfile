# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# gcdump/dotnet-gcdump.dockerfile — dotnet-autopsy/gcdump : per-case `.gcdump`
# heap-snapshot analysis image. Thin case layer on top of the shared
# dotnet-autopsy-base.
#
# Build (context = REPO ROOT so COPY can reach common/ + gcdump/ + the
#        gcdump file; the shared base must be built first):
#   docker build -f common/base.dockerfile        -t dotnet-autopsy-base .
#   docker build -f gcdump/dotnet-gcdump.dockerfile -t dotnet-autopsy-gcdump \
#       --build-arg GCDUMP_FILE=heap.gcdump .
#   (or: docker compose --profile gcdump build ;
#        ./build.sh gcdump ; ./demo.sh gcdump.)
#
# Required build inputs (repo root): the .gcdump capture (GCDUMP_FILE).
#
# Key build args:
#   GCDUMP_FILE — gcdump filename (default: heap.gcdump)
#   DUMP_ARCH   — informational; gcdumps are arch-portable, so just the
#                 image platform label (amd64 default).
#   SMOKE_TEST  — set to 1 to run the in-image gcdump smoke at build time
# ─────────────────────────────────────────────────────────────────────────────

ARG DUMP_ARCH=amd64
ARG GCDUMP_FILE=heap.gcdump
ARG SMOKE_TEST=0

FROM dotnet-autopsy-base AS analysis

ARG GCDUMP_FILE=heap.gcdump
ARG DUMP_ARCH=amd64
ARG SMOKE_TEST=0

ENV CASE_GCDUMP=/analysis/${GCDUMP_FILE}

# ── gcdump-specific scripts + the gcdump triage app ──────────────────────────
# BCL-only file-based app (no NuGet — gcdump triage parses the text report
# emitted by dotnet-gcdump, which is authoritative). See RUNBOOK
# "Extending the report tools" for the NativeAOT-off publish discipline.
COPY gcdump/analyze-gcdump.sh gcdump/gcdump_triage.cs /opt/
RUN chmod +x /opt/analyze-gcdump.sh

# ── Publish the gcdump triage app ────────────────────────────────────────────
RUN export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
    && dotnet publish /opt/gcdump_triage.cs -c Release -o /opt/report-bin/gcdump_triage \
           -p:PublishAot=false -p:PublishSingleFile=false --self-contained false \
           > /tmp/pub-gcdump-triage.log 2>&1 \
       || { echo "ERROR: publish gcdump_triage failed"; cat /tmp/pub-gcdump-triage.log; exit 1; } \
    && rm -f /tmp/pub-gcdump-triage.log \
    && echo "Gcdump triage app published to /opt/report-bin/gcdump_triage"

# Reusable-sources: add the gcdump triage app next to the shared apps +
# README the base already baked into /analysis/sources/.
COPY gcdump/gcdump_triage.cs /analysis/sources/

# ── Optional end-to-end smoke (SMOKE_TEST=1 only) ─────────────────────────────
# Generates a tiny .NET allocating workload in the background, dotnet-gcdump
# collects a snapshot of it, then dotnet-gcdump report runs against the
# snapshot. Off by default. Used by the rot-check CI workflow.
ENV SMOKE_TEST=${SMOKE_TEST}
RUN <<'SMOKE_EOF'
set -u
if [ "${SMOKE_TEST}" != "1" ]; then
    echo "SMOKE_TEST=${SMOKE_TEST} — skipping in-image gcdump smoke."
    exit 0
fi
set -e
echo "=== SMOKE_TEST=1: gcdump end-to-end chain test ==="
SDK_MAJOR=$(dotnet --version | cut -d. -f1)
mkdir -p /tmp/smokeapp/heapapp
cat > /tmp/smokeapp/heapapp/heapapp.csproj <<CSPROJ
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net${SDK_MAJOR}.0</TargetFramework>
  </PropertyGroup>
</Project>
CSPROJ
cat > /tmp/smokeapp/heapapp/Program.cs <<'CS'
// Smoke workload — allocate a population of objects then idle so
// dotnet-gcdump collect can attach and snapshot. Multiple type shapes
// (strings, byte arrays, dictionary entries) so the top-types table
// is interesting.
//
// Static fields (declared AFTER the top-level statements per C# top-
// level program rules) keep the collections rooted across Thread.Sleep.
// JIT register-pressure analysis can otherwise eliminate Main-local
// refs after their last read, GC frees them, and the snapshot captures
// only startup heap.
using System.Collections.Generic;
using System.Threading;
for (int i = 0; i < 5000; i++)
{
    Roots.Strs.Add("hello_" + i);
    Roots.Bufs.Add(new byte[4096]);
    Roots.Map[i] = "value_" + i;
}
System.Console.WriteLine("heapapp ready " + Roots.Strs.Count);
Thread.Sleep(30000);

static class Roots
{
    public static List<string>            Strs = new();
    public static List<byte[]>            Bufs = new();
    public static Dictionary<int,string>  Map  = new();
}
CS
cd /tmp/smokeapp/heapapp
dotnet build -c Release -o bin >/dev/null
/tmp/smokeapp/heapapp/bin/heapapp &
APP_PID=$!
# 8 s margin for cold-container startup + JIT + allocation loop;
# 4 s was tight enough that the snapshot sometimes missed the
# workload allocations on a busy/slow runner.
sleep 8
dotnet-gcdump collect -p $APP_PID -o /tmp/smoke.gcdump 2>/dev/null || true
kill -9 $APP_PID 2>/dev/null || true; wait 2>/dev/null || true
[ -s /tmp/smoke.gcdump ] || { echo "ERROR: smoke gcdump not created"; exit 1; }
echo "Smoke gcdump created: $(stat -c%s /tmp/smoke.gcdump) bytes"
dotnet-gcdump report /tmp/smoke.gcdump | head -10 || { echo "ERROR: report failed"; exit 1; }
echo "=== SMOKE_TEST: gcdump end-to-end chain PASSED ==="
rm -rf /tmp/smokeapp /tmp/smoke.gcdump
SMOKE_EOF

# ── Case inputs + docs/sources baking ────────────────────────────────────────
RUN mkdir -p /symbols-user

RUN mkdir -p /analysis/docs /analysis/docker
COPY README.md gcdump/RUNBOOK.md /analysis/docs/
COPY common/base.dockerfile gcdump/dotnet-gcdump.dockerfile docker-compose.yml .dockerignore \
     gcdump/analyze-gcdump.sh common/entrypoint.sh gcdump/gcdump_triage.cs common/analysis_md.cs \
     common/json-get.cs build.sh build.ps1 \
     gcdump/smoke.sh demo.sh \
     /analysis/docker/

COPY ${GCDUMP_FILE} /analysis/${GCDUMP_FILE}

# Write MOTD for interactive sessions
RUN cat > /analysis/.motd << 'MOTD'

══════════════════════════════════════════════════════════════════════════
  dotnet-autopsy · gcdump  ·  .NET managed heap snapshot
══════════════════════════════════════════════════════════════════════════

  Welcome. This self-contained container already analyzed the baked
  .gcdump at build time — heap summary, top types by size, heuristic
  flags. No prior dotnet-gcdump knowledge is needed to read the results;
  the interactive tools below take you deeper when you want.

  YOUR ANALYSIS IS READY        (URLs are clickable in most terminals)
  ──────────────────────
    Rendered report : http://localhost:5550/analysis/analysis.md   ← start
    Raw output      : http://localhost:5550/analysis/analysis.txt
                      path /analysis/analysis.txt — authoritative source
    Machine status  : http://localhost:5550/analysis/status.json
    Hand-off guide  : http://localhost:5550/analysis/docs/RUNBOOK.md
    Reusable apps   : http://localhost:5550/analysis/sources/
                      the standalone .NET 10 report apps + how to reuse them
    File server     : http://localhost:5550/          browse everything
    Re-show this    : cat /analysis/.motd

  INTERACTIVE ANALYSIS  —  start here
  ───────────────────────────────────
    dotnet-gcdump report $CASE_GCDUMP
                 — re-run the full type-listing (default sort by bytes).

    dotnet-gcdump report $CASE_GCDUMP | head -30
                 — see only the top entries.

    NOTE: this v1 triage parses dotnet-gcdump's text report. Direct
    .gcdump heap-graph traversal (paths-to-roots, holds-X-alive) is the
    planned v1.1 enhancement (TraceEvent-style depth) and not in v1.

  USEFUL dotnet-gcdump commands   (general)
  ─────────────────────────────────────────
    dotnet-gcdump ps                       list .NET processes you can snapshot
    dotnet-gcdump collect -p <pid> -o X    snapshot a running process to X
    dotnet-gcdump report <file>            text report (top types by bytes)
    dotnet-gcdump convert <nettrace>       convert a .nettrace to .gcdump

  WHAT'S INSTALLED   (all on PATH, in every shell)
  ────────────────────────────────────────────────
    .NET / SDK  dotnet (full SDK — build & repro), dotnet-gcdump,
                dotnet-trace, dotnet-counters, dotnet-stack, dotnet-dump,
                dotnet-sos, dotnet-symbol, dotnet-monitor (installed)
    Native/ELF  lldb, gdb, eu-unstrip, eu-readelf, eu-stack, addr2line,
                objdump, nm, readelf, strings, file
    Scripting   pwsh  — PowerShell 7 (automate triage, parse analysis.txt)
    Editor      fresh — full terminal editor   ·   nano — minimal fallback
    Monitor     btop  ·  top  ·  ps

  WHERE THINGS LIVE
  ─────────────────
    /analysis/         the gcdump, analysis.md / .txt, status.json
    /analysis/docs/    README.md, RUNBOOK.md  (rendered by the file server)
    /analysis/docker/  the Dockerfiles + build/run scripts that built this
    /analysis/sources/ the standalone-reusable .NET 10 report apps
    $CASE_GCDUMP       env var → the baked .gcdump

  New here?  Open the rendered report URL above and read the TOP TYPES
             BY SIZE section.  That's it.
══════════════════════════════════════════════════════════════════════════

MOTD

# Run gcdump analysis at build time
RUN /opt/analyze-gcdump.sh

EXPOSE 5550
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD curl -fL http://localhost:5550/ || exit 1

ENTRYPOINT ["/bin/bash", "/opt/entrypoint.sh"]
