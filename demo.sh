#!/bin/bash
# demo.sh — build a real-input analysis image and LEAVE IT RUNNING for
# interactive inspection (the rendered report + the welcome screen).
#
# Purpose: manual acceptance-testing of a release. Unlike smoke.sh (a
# self-cleaning pass/fail CI test) and rot-check.yml (CI), this stands up a
# persistent container you can browse and `docker exec` into, and it is
# idempotent — re-run it after each change to eyeball the latest build.
#
# Self-contained & OS-agnostic: it generates its own throwaway input inside
# a disposable SDK container and copies it out with `docker cp` (no real
# artifact needed, no host .NET, no bind-mount pitfalls). The synthetic
# input is never committed (covered by *.dump / *.nettrace in .gitignore)
# and is removed from disk after it is baked into the image.
#
# Usage:
#   ./demo.sh [sos|trace] [--restart] [--build-arg KEY=VALUE ...]
#     sos       (default) build dotnet-autopsy/sos around a synthetic dump
#     trace     build dotnet-autopsy/trace around a synthetic .nettrace
#     --restart also set `--restart unless-stopped` so the demo survives
#               Docker/host restarts.
#
# Tear down when done:
#   docker rm -f dotnet-autopsy-demo-<slug> && docker rmi dotnet-autopsy-demo-<slug>

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# First arg = image slug (sos|trace|gcdump), default sos. Shift only if present.
SLUG="${1:-sos}"
case "${SLUG}" in
    sos|trace|gcdump) shift || true ;;
    -*|"")            SLUG="sos" ;;
    *)                echo "ERROR: unknown image '${SLUG}' (expected sos|trace|gcdump)" >&2
                      exit 2 ;;
esac

IMAGE="dotnet-autopsy-demo-${SLUG}"
CONTAINER="dotnet-autopsy-demo-${SLUG}"
GEN_NAME="dotnet-autopsy-demo-${SLUG}-gen-$$"
DUMP_ARCH="${DUMP_ARCH:-amd64}"
DOTNET_SDK_IMAGE="${DOTNET_SDK_IMAGE:-mcr.microsoft.com/dotnet/sdk:10.0}"
HOST_PORT="${DEMO_PORT:-5550}"

case "${SLUG}" in
    sos)
        IMAGE_DOCKERFILE="sos/dotnet-sos.dockerfile"
        INPUT_NAME="demo-core.dump"
        INPUT_BUILDARG="DUMP_FILE"
        ;;
    trace)
        IMAGE_DOCKERFILE="trace/dotnet-trace.dockerfile"
        INPUT_NAME="demo-trace.nettrace"
        INPUT_BUILDARG="TRACE_FILE"
        ;;
    gcdump)
        IMAGE_DOCKERFILE="gcdump/dotnet-gcdump.dockerfile"
        INPUT_NAME="demo-heap.gcdump"
        INPUT_BUILDARG="GCDUMP_FILE"
        ;;
esac
INPUT_PATH="${DIR}/${INPUT_NAME}"

RESTART_ARGS=()
PASS_ARGS=()
for a in "$@"; do
    case "$a" in
        --restart) RESTART_ARGS=(--restart unless-stopped) ;;
        *) PASS_ARGS+=("$a") ;;
    esac
done

# Only the generator + the throwaway input are transient. The demo
# container/image are intentionally LEFT in place.
cleanup() {
    docker rm -f "${GEN_NAME}" >/dev/null 2>&1 || true
    rm -f "${INPUT_PATH}" 2>/dev/null || true
}
trap cleanup EXIT

echo "══════════════════════════════════════════════════════════════════"
echo "  dotnet-autopsy · ${SLUG}  demo  ·  persistent interactive instance"
echo "  platform linux/${DUMP_ARCH}  ·  base ${DOTNET_SDK_IMAGE}"
echo "══════════════════════════════════════════════════════════════════"

echo ""
echo "Step 1/4 — generating a content-rich throwaway ${SLUG} input..."
docker rm -f "${GEN_NAME}" >/dev/null 2>&1 || true

if [ "${SLUG}" = "sos" ]; then
    docker run --name "${GEN_NAME}" --platform "linux/${DUMP_ARCH}" \
        "${DOTNET_SDK_IMAGE}" bash -c '
            set -e
            M=$(dotnet --version | cut -d. -f1)
            mkdir -p /tmp/app && cd /tmp/app
            cat > app.csproj <<CSPROJ
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net${M}.0</TargetFramework>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
CSPROJ
            cat > Program.cs <<CS
using System;using System.Collections.Generic;using System.Threading;
var names=new List<string>();
for(int i=0;i<8000;i++) names.Add(\$"customer-{i}-{Guid.NewGuid()}");
var cache=new Dictionary<int,byte[]>();
for(int i=0;i<400;i++) cache[i]=new byte[4096];
new Thread(()=>Thread.Sleep(Timeout.Infinite)){IsBackground=true,Name="worker-A"}.Start();
try { throw new InvalidOperationException("simulated failure for the dotnet-autopsy demo dump"); }
catch(Exception ex) { Environment.FailFast("demo: unhandled in pipeline", ex); }
CS
            DOTNET_DbgEnableMiniDump=1 \
                DOTNET_DbgMiniDumpName=/tmp/demo.dump \
                DOTNET_DbgMiniDumpType=4 \
                dotnet run 2>/dev/null || true
            [ -f /tmp/demo.dump ] || { echo "ERROR: dump not created"; exit 1; }
            echo "dump bytes: $(stat -c%s /tmp/demo.dump)"
        '
    docker cp "${GEN_NAME}:/tmp/demo.dump" "${INPUT_PATH}"
elif [ "${SLUG}" = "trace" ]; then
    # trace: workload + dotnet-trace collect (tool-install inside the
    # disposable SDK container so this works even on a fresh clone before
    # dotnet-autopsy-base exists locally).
    docker run --name "${GEN_NAME}" --platform "linux/${DUMP_ARCH}" \
        "${DOTNET_SDK_IMAGE}" bash -c '
            set -e
            export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
            M=$(dotnet --version | cut -d. -f1)
            mkdir -p /opt/dt && dotnet tool install dotnet-trace --tool-path /opt/dt >/dev/null
            export PATH="/opt/dt:${PATH}"
            mkdir -p /tmp/app && cd /tmp/app
            cat > app.csproj <<CSPROJ
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net${M}.0</TargetFramework>
  </PropertyGroup>
</Project>
CSPROJ
            cat > Program.cs <<\CS
// A content-rich CPU/alloc workload: several distinct named methods so the
// trace top-CPU report has multiple recognisable application-level
// functions to rank (not just one hotspot).
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Threading;

new Thread(BackgroundWorker) { IsBackground = true, Name = "worker-A" }.Start();

var sw = System.Diagnostics.Stopwatch.StartNew();
long total = 0;
while (sw.Elapsed.TotalSeconds < 4)
{
    total += HashRecords(48);
    total += ParseAndSum(2000);
    total += AllocateBuffers(16);
    total += IndexLookup(400);
}
Console.WriteLine("done " + total);

static void BackgroundWorker()
{
    var w = System.Diagnostics.Stopwatch.StartNew();
    while (w.Elapsed.TotalSeconds < 4) Thread.Sleep(25);
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
            dotnet-trace collect --format nettrace -o /tmp/demo.nettrace -- /tmp/app/bin/app 2>/dev/null || true
            [ -s /tmp/demo.nettrace ] || { echo "ERROR: nettrace not created"; exit 1; }
            echo "trace bytes: $(stat -c%s /tmp/demo.nettrace)"
        '
    docker cp "${GEN_NAME}:/tmp/demo.nettrace" "${INPUT_PATH}"
elif [ "${SLUG}" = "gcdump" ]; then
    # gcdump: allocating workload in background + dotnet-gcdump collect by
    # pid + kill workload. dotnet-gcdump is tool-installed inside the
    # disposable SDK container (same fresh-clone friendliness as trace).
    docker run --name "${GEN_NAME}" --platform "linux/${DUMP_ARCH}" \
        "${DOTNET_SDK_IMAGE}" bash -c '
            set -e
            export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
            M=$(dotnet --version | cut -d. -f1)
            mkdir -p /opt/dg && dotnet tool install dotnet-gcdump --tool-path /opt/dg >/dev/null
            export PATH="/opt/dg:${PATH}"
            mkdir -p /tmp/app && cd /tmp/app
            cat > app.csproj <<CSPROJ
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net${M}.0</TargetFramework>
  </PropertyGroup>
</Project>
CSPROJ
            cat > Program.cs <<\CS
// Allocate a varied population — strings, byte buffers, a sized cache, a
// type-keyed dictionary — so the gcdump top-types report has multiple
// distinct application-level entries to rank (not just one dominator).
//
// Static fields (declared AFTER the top-level statements, per C# top-level
// program rules) keep the collections rooted across Thread.Sleep — JIT
// register-pressure analysis can otherwise eliminate Main-local refs
// after their last read, GC frees them, and dotnet-gcdump captures a
// startup-only heap (~70 KB) instead of the ~70 MB workload heap.
//
// NB: no C-sharp dollar-interp here and no dollar-curly-anything. The
// outer bash wrapper (single-quoted bash -c) effectively unquotes the
// heredoc delimiter, re-enabling shell expansion in the body, so any
// $-sigil would be eaten by the host shell before the file is written.
using System;
using System.Collections.Generic;
using System.Threading;

for (int i = 0; i < 8000; i++)
{
    Roots.Strs.Add("customer-" + i);
    Roots.Bufs.Add(new byte[8192]);
    Roots.Labels[i] = "label-" + i;
}
for (int i = 0; i < 400; i++)
{
    var a = new int[1024];
    for (int j = 0; j < a.Length; j++) a[j] = i * j;
    Roots.Arrays[i] = a;
}
Console.WriteLine("heapapp ready strs=" + Roots.Strs.Count
    + " bufs="   + Roots.Bufs.Count
    + " labels=" + Roots.Labels.Count
    + " arrays=" + Roots.Arrays.Count);
Thread.Sleep(30000);

static class Roots
{
    public static List<string>            Strs   = new();
    public static List<byte[]>            Bufs   = new();
    public static Dictionary<int,string>  Labels = new();
    public static Dictionary<int,int[]>   Arrays = new();
}
CS
            dotnet build -c Release -o bin >/dev/null
            ./bin/app &
            APP_PID=$!
            # 8 s margin: dotnet startup + JIT + ~70 MB allocation loop +
            # entering Thread.Sleep. 4 s was tight on a cold container and
            # snapshotted a startup-only heap. (No apostrophes in comments
            # inside this single-quoted bash -c block.)
            sleep 8
            dotnet-gcdump collect -p $APP_PID -o /tmp/demo.gcdump 2>/dev/null || true
            kill -9 $APP_PID 2>/dev/null || true; wait 2>/dev/null || true
            [ -s /tmp/demo.gcdump ] || { echo "ERROR: gcdump not created"; exit 1; }
            echo "gcdump bytes: $(stat -c%s /tmp/demo.gcdump)"
        '
    docker cp "${GEN_NAME}:/tmp/demo.gcdump" "${INPUT_PATH}"
fi
docker rm -f "${GEN_NAME}" >/dev/null 2>&1 || true
[ -s "${INPUT_PATH}" ] || { echo "ERROR: demo input not copied out"; exit 1; }
echo "Step 1/4 — input generated ($(wc -c < "${INPUT_PATH}") bytes)"

echo ""
echo "Step 2/4 — building the image (replaces any previous ${SLUG} demo)..."
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker build \
    --platform "linux/${DUMP_ARCH}" \
    -f "${DIR}/common/base.dockerfile" \
    -t dotnet-autopsy-base \
    --build-arg "DUMP_ARCH=${DUMP_ARCH}" \
    --build-arg "DOTNET_SDK_IMAGE=${DOTNET_SDK_IMAGE}" \
    "${DIR}"
docker build \
    --platform "linux/${DUMP_ARCH}" \
    -f "${DIR}/${IMAGE_DOCKERFILE}" \
    -t "${IMAGE}" \
    --build-arg "DUMP_ARCH=${DUMP_ARCH}" \
    --build-arg "${INPUT_BUILDARG}=${INPUT_NAME}" \
    "${PASS_ARGS[@]}" \
    "${DIR}"
rm -f "${INPUT_PATH}"   # baked into the image; never leave it on disk
echo "Step 2/4 — build PASSED"

echo ""
echo "Step 3/4 — starting the persistent container..."
docker run -d \
    --platform "linux/${DUMP_ARCH}" \
    --name "${CONTAINER}" \
    "${RESTART_ARGS[@]}" \
    -p "127.0.0.1:${HOST_PORT}:5550" \
    "${IMAGE}" >/dev/null
for i in $(seq 1 40); do
    docker exec "${CONTAINER}" curl -sf http://localhost:5550/ >/dev/null 2>&1 \
        && break
    [ "${i}" -eq 40 ] && { echo "ERROR: server did not come up"; \
        docker logs "${CONTAINER}" 2>&1 | tail; exit 1; }
    sleep 2
done
STATUS=$(docker exec "${CONTAINER}" json-get /analysis/status.json status \
    2>/dev/null || echo unknown)
echo "Step 3/4 — running (analysis status: ${STATUS})"

echo ""
echo "Step 4/4 — ready."
echo "══════════════════════════════════════════════════════════════════"
echo "  Rendered report : http://localhost:${HOST_PORT}/analysis/analysis.md"
echo "  Raw output      : http://localhost:${HOST_PORT}/analysis/analysis.txt"
echo "  Browse files    : http://localhost:${HOST_PORT}/"
echo "  Welcome screen  : docker exec -it ${CONTAINER} bash"
case "${SLUG}" in
    sos)
        echo "  Interactive SOS : docker exec -it ${CONTAINER} delve" ;;
    trace)
        echo "  Speedscope JSON : http://localhost:${HOST_PORT}/analysis/trace.speedscope.json"
        echo "                    open in https://www.speedscope.app/ (flame graph)" ;;
    gcdump)
        echo "  Re-report       : docker exec ${CONTAINER} dotnet-gcdump report \$CASE_GCDUMP | head -30" ;;
esac
echo ""
echo "  Tear down       : docker rm -f ${CONTAINER} && docker rmi ${IMAGE}"
echo "══════════════════════════════════════════════════════════════════"
