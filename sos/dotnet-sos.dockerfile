# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# sos/dotnet-sos.dockerfile — dotnet-autopsy/sos : per-case .NET core-dump
# analysis image. Thin case layer on top of the shared dotnet-autopsy-base.
#
# Build (context = REPO ROOT so COPY can reach common/ + sos/ + the dump;
#        the shared base must be built first):
#   docker build -f common/base.dockerfile  -t dotnet-autopsy-base .
#   docker build -f sos/dotnet-sos.dockerfile -t dotnet-autopsy-sos \
#       --build-arg DUMP_FILE=core.dump .
#   (or: docker compose build ; ./build.sh ; ./demo.sh — all orchestrate this)
#
# Required build inputs (repo root): the dump (DUMP_FILE), optional symbols/.
#
# Key build args:
#   DUMP_FILE             — dump filename (default: core.dump)
#   DUMP_ARCH             — dump/image CPU arch: amd64 (default) or arm64.
#                           MUST match the dump, NOT the build host.
#   INNER_EXCEPTION_DEPTH — max wrapped-inner-exception expansion (default 9)
#   SMOKE_TEST            — set to 1 to run the end-to-end smoke at build time
# ─────────────────────────────────────────────────────────────────────────────

ARG DUMP_ARCH=amd64
ARG DUMP_FILE=core.dump
ARG INNER_EXCEPTION_DEPTH=9
ARG SMOKE_TEST=0

FROM dotnet-autopsy-base AS analysis

# Re-declare ARGs after FROM (Docker scope rule)
ARG DUMP_FILE=core.dump
ARG DUMP_ARCH=amd64
# Max wrapped-inner-exception expansion passes in analyze.sh § 6b
# (0 disables). Per-case knob: deeply-nested chains may need a higher
# value; each pass reloads the dump, so it bounds analysis time.
ARG INNER_EXCEPTION_DEPTH=9
ARG SMOKE_TEST=0

ENV CASE_DUMP=/analysis/${DUMP_FILE}
ENV INNER_EXCEPTION_DEPTH=${INNER_EXCEPTION_DEPTH}

# ── SOS-specific scripts + the dump triage app ────────────────────────────────
COPY sos/analyze.sh sos/delve-lldb.sh sos/dsos-info.sh sos/triage_summary.cs /opt/
RUN chmod +x /opt/analyze.sh \
    && install -m 0755 /opt/dsos-info.sh /usr/local/bin/dsos-info \
    # delve     — dotnet-dump analyze (managed; needs no app binary)
    # delve-lldb — raw lldb + SOS (needs the app binary lldb uses to load core)
    && printf '#!/bin/bash\n# Pre-configured dotnet-dump analyze wrapper\nexec dotnet-dump analyze "${CASE_DUMP:-/analysis/core.dump}" \\\n    -c "setsymbolserver -ms -cache ${FILES_DIR}/symbols" \\\n    -c "setsymbolserver -directory /symbols-user" \\\n    "$@"\n' \
        > /usr/local/bin/delve \
    && chmod +x /usr/local/bin/delve \
    && install -m 0755 /opt/delve-lldb.sh /usr/local/bin/delve-lldb

# ── Publish the SOS triage app (analysis_md + json-get are in the base) ───────
# Same cached/pristine-stdout discipline as the base publish step; the
# NativeAOT-off + framework-dependent flags are mandatory (.NET 10 file-based
# `dotnet publish` defaults to NativeAOT — see RUNBOOK "Extending the report
# tools"). Apphost path /opt/report-bin/triage_summary/triage_summary.
RUN export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
    && dotnet publish /opt/triage_summary.cs -c Release -o /opt/report-bin/triage_summary \
           -p:PublishAot=false -p:PublishSingleFile=false --self-contained false \
           > /tmp/pub-triage.log 2>&1 \
       || { echo "ERROR: publish triage_summary failed"; cat /tmp/pub-triage.log; exit 1; } \
    && rm -f /tmp/pub-triage.log \
    && echo "SOS triage app published to /opt/report-bin/triage_summary"

# Reusable-sources: add the SOS triage app next to the shared apps + README
# the base already baked into /analysis/sources/.
COPY sos/triage_summary.cs /analysis/sources/

# ── Optional end-to-end smoke (SMOKE_TEST=1 only) ─────────────────────────────
# Generates a real .NET crash dump inside the image and analyzes it (the
# dump-specific chain test; the shared toolchain smoke is in the base). Off
# by default (adds ~60-90 s). Used by the rot-check CI workflow.
#
# MUST use the BuildKit heredoc-RUN form. The earlier `RUN cmd && cat <<EOF`
# form is a Dockerfile PARSE error. Outer delimiter is quoted ('SMOKE_EOF')
# so BuildKit does NOT expand ${SDK_MAJOR}; SMOKE_TEST is read from ENV.
ENV SMOKE_TEST=${SMOKE_TEST}
RUN <<'SMOKE_EOF'
set -u
if [ "${SMOKE_TEST}" != "1" ]; then
    echo "SMOKE_TEST=${SMOKE_TEST} — skipping in-image end-to-end smoke."
    exit 0
fi
set -e
echo "=== SMOKE_TEST=1: End-to-end chain test ==="
SDK_MAJOR=$(dotnet --version | cut -d. -f1)
mkdir -p /tmp/smokeapp/crashapp
cat > /tmp/smokeapp/crashapp/crashapp.csproj <<CSPROJ
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net${SDK_MAJOR}.0</TargetFramework>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
CSPROJ
printf 'System.Environment.FailFast("smoke-test-crash");\n' > /tmp/smokeapp/crashapp/Program.cs
cd /tmp/smokeapp/crashapp
DOTNET_DbgEnableMiniDump=1 \
    DOTNET_DbgMiniDumpName=/tmp/smoke.dump \
    DOTNET_DbgMiniDumpType=4 \
    dotnet run 2>/dev/null || true
[ -f /tmp/smoke.dump ] || { echo "ERROR: smoke dump not created"; exit 1; }
echo "Smoke dump created: $(stat -c%s /tmp/smoke.dump) bytes"
dotnet-dump analyze /tmp/smoke.dump \
    -c "runtimes" \
    -c "clrthreads" \
    -c "printexception" \
    -c "exit"
echo "=== SMOKE_TEST: End-to-end chain PASSED ==="
rm -rf /tmp/smokeapp /tmp/smoke.dump
SMOKE_EOF

# ── Case inputs + docs/sources baking ─────────────────────────────────────────
# Create dirs; ENV vars already set from the base.
RUN mkdir -p /analysis/symbols /symbols-user

# Dump + user symbols — order matters for cache: symbols rarely change,
# dump changes per-case. Reverse order maximises reuse.
COPY symbols/ /symbols-user/

# Bake the project docs + build/run sources UNDER /analysis so the file
# server (root=/analysis) serves them. .md is rendered; sources are text.
# DISTINCT from /analysis/sources/ (the standalone-reusable apps). Before
# the per-case dump COPY so editing a source doesn't re-copy the dump layer.
RUN mkdir -p /analysis/docs /analysis/docker
COPY README.md sos/RUNBOOK.md /analysis/docs/
COPY common/base.dockerfile sos/dotnet-sos.dockerfile docker-compose.yml .dockerignore \
     sos/analyze.sh common/entrypoint.sh sos/triage_summary.cs common/analysis_md.cs \
     common/json-get.cs sos/delve-lldb.sh sos/dsos-info.sh build.sh build.ps1 \
     sos/smoke.sh demo.sh \
     /analysis/docker/

COPY ${DUMP_FILE} /analysis/${DUMP_FILE}

# Write MOTD for interactive sessions
RUN cat > /analysis/.motd << 'MOTD'

══════════════════════════════════════════════════════════════════════════
  dotnet-autopsy · sos  ·  Linux .NET core-dump  ·  post-mortem + dev env
══════════════════════════════════════════════════════════════════════════

  Welcome. This self-contained container already analyzed the baked core
  dump at build time. No prior SOS or lldb knowledge is needed to read the
  results — the interactive tools below take you deeper when you want them.

  YOUR ANALYSIS IS READY        (URLs are clickable in most terminals)
  ──────────────────────
    Rendered report : http://localhost:5550/analysis/analysis.md   ← start
    Raw output      : http://localhost:5550/analysis/analysis.txt
                      path /analysis/analysis.txt — authoritative source
    Machine status  : http://localhost:5550/analysis/status.json
                      path /analysis/status.json — success|partial|failed
    Hand-off guide  : http://localhost:5550/analysis/docs/RUNBOOK.md
                      (rendered; raw docs/sources under /analysis/docker/)
    Reusable apps   : http://localhost:5550/analysis/sources/
                      the standalone .NET 10 report apps + how to reuse them
    File server     : http://localhost:5550/          browse everything
    Image info      : run  dsos-info   — fileserver version, env, symbols
    Re-show this    : cat /analysis/.motd

  INTERACTIVE ANALYSIS  —  start here
  ───────────────────────────────────
    delve        dotnet-dump analyze with symbol paths preconfigured.
                 Simplest path, needs NO app binary.  ← recommended

    delve-lldb   lldb + SOS (same SOS commands, native-debugger host).
                 Requires lldb — always present on the canonical Microsoft
                 .NET SDK base; absent on the Chainguard / Wolfi free-tier
                 variant (the wrapper detects this and prints clear
                 guidance pointing back to `delve`).
                 lldb needs the executable that produced the core; this
                 wrapper finds it automatically from the dump's recorded
                 path. Framework-dependent apps (run as `dotnet App.dll`)
                 need nothing extra; for self-contained / apphost apps,
                 drop the app binary into ./symbols/ before building.

    HEADS-UP: A BARE `lldb -c <dump>` DOES NOT WORK ("no associated
    executable images"). ALWAYS USE delve-lldb (OR delve) ON THE CORE.

  USEFUL SOS COMMANDS   (type at the delve / delve-lldb  >  prompt)
  ────────────────────────────────────────────────────────────────
    clrthreads            all managed threads (faulting thread marked)
    clrstack -all         managed stacks, every thread
    pe / printexception   current exception   (-nested for inner chain)
    dumpheap -stat        managed heap: type counts + total sizes
    gcroot <addr>         what is keeping an object alive
    eeheap -gc            GC heap segments, generations, sizes
    syncblk               monitor lock table (deadlock hunting)
    threadpool            thread-pool queue + worker state
    finalizequeue         finalizer backlog
    analyzeoom            out-of-memory analysis
    setsymbolserver -ms   use Microsoft public symbols
    setclrpath <dir>      point SOS at a custom DAC (non-MS runtimes)

  WHAT'S INSTALLED   (all on PATH, in every shell)
  ────────────────────────────────────────────────
    .NET / SDK  dotnet (full SDK — build & repro), dotnet-dump, dotnet-sos,
                dotnet-trace, dotnet-counters, dotnet-gcdump, dotnet-stack,
                dotnet-symbol, dotnet-monitor (installed, not run)
    Native/ELF  lldb (canonical base; may be absent on Chainguard), gdb,
                eu-unstrip, eu-readelf, eu-stack, addr2line, objdump, nm,
                readelf, strings, file
    Scripting   pwsh  — PowerShell 7 (automate triage, parse analysis.txt)
    Editor      fresh — full terminal editor   ·   nano — minimal fallback
    Monitor     btop  ·  top  ·  ps   (watch the analysis workload)
    Image info  dsos-info — fileserver version, project env, symbol cache

  WHERE THINGS LIVE
  ─────────────────
    /analysis/         the dump, analysis.md / .txt, status.json, symbols/
    /analysis/docs/    README.md, RUNBOOK.md  (rendered by the file server)
    /analysis/docker/  the Dockerfiles + build/run scripts that built this
    /analysis/sources/ the standalone-reusable .NET 10 report apps
    /symbols-user/     your PDBs / app binary (baked from ./symbols/)
    $CASE_DUMP         env var → the baked core dump
    $INNER_EXCEPTION_DEPTH  inner-exc unwind passes (default 9; 0=off)
    counts / versions  run  dsos-info  (symbol-cache size, fileserver build)

  New here?  Run  delve , then try  clrthreads  and  pe .  That's it.
══════════════════════════════════════════════════════════════════════════

MOTD

# Run analysis at build time
# Arch guard + symbol fetch + dotnet-dump + triage summary are all in analyze.sh
RUN /opt/analyze.sh

EXPOSE 5550
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD curl -fL http://localhost:5550/ || exit 1

ENTRYPOINT ["/bin/bash", "/opt/entrypoint.sh"]
