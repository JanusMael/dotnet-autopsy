# Runbook — analyzing a .NET core dump with dotnet-autopsy/sos

Hand this document to anyone who needs to diagnose a Linux .NET crash dump.
No prior knowledge of SOS or lldb is required to follow the automated path;
the interactive section requires basic comfort with a terminal.

---

## Contents

1. [Prerequisites](#prerequisites)
2. [Step 0 — Capture a good dump at the origin](#step-0--capture-a-good-dump-at-the-origin)
3. [Step 1 — Prepare inputs](#step-1--prepare-inputs)
4. [Step 2 — Build the analysis image](#step-2--build-the-analysis-image)
5. [Step 3 — Read the automated analysis](#step-3--read-the-automated-analysis)
6. [Step 4 — Dive deeper interactively](#step-4--dive-deeper-interactively)
7. [SOS command cheat-sheet](#sos-command-cheat-sheet)
8. [How to determine the runtime version of a dump](#how-to-determine-the-runtime-version-of-a-dump)
9. [Troubleshooting](#troubleshooting)
10. [Platform — same commands on all OSes](#platform--same-commands-on-all-oses)
11. [Offline use and air-gapped builds](#offline-use-and-air-gapped-builds)
12. [Reproducing a past case](#reproducing-a-past-case)
13. [Lifecycle and cleanup](#lifecycle-and-cleanup)
14. [References](#references)

---

## Prerequisites

- **Docker Desktop** (Windows or macOS) or **Docker Engine** (Linux).
  - Windows: WSL2 backend recommended.
  - macOS Apple Silicon: enable "Use Rosetta for x86/amd64 emulation" in
    Docker Desktop → Settings → General. Allocate ≥8 GB RAM to the VM.
- **Network access at build time** — the build fetches the matching DAC from
  the Microsoft symbol server and downloads the file server binary. The
  resulting image runs fully offline.
- The **core dump file** and (optionally) **PDB files** from the crashed application.

---

## Step 0 — Capture a good dump at the origin

The quality of analysis depends on dump quality. Always prefer a **full dump**.

### Automatic crash dump (recommended)

Set these environment variables on the application container before the crash:

```sh
DOTNET_DbgEnableMiniDump=1
DOTNET_DbgMiniDumpType=4          # 4 = Full; 1 = Mini; 2 = Heap; 3 = Triage
DOTNET_DbgMiniDumpName=/tmp/core  # will produce /tmp/core.<pid>
```

The runtime writes the dump automatically on unhandled exceptions and
`Environment.FailFast` [[⁶]](#references).

### Manual capture with `createdump`

```sh
# Find createdump alongside the .NET runtime
find /usr -name createdump 2>/dev/null

# Full dump of pid 1234
createdump --full 1234 --output /tmp/core.dump
```

### Manual capture with `dotnet-dump collect`

```sh
dotnet-dump collect --process-id 1234 --type Full --output /tmp/core.dump
```

### ⚠ Avoid `gdb`/`gcore` for .NET dumps

Dumps captured with `gdb core <pid>` or `gcore` do not include all managed
state. Many SOS commands will show "UNKNOWN" for type and function names
because the managed heap is absent [[⁶]](#references). Always prefer
`createdump` or `dotnet-dump collect`.

---

## Step 1 — Prepare inputs

Clone or open this repository, then:

```sh
# Required: copy the core dump to the repo root
cp /path/to/core.dump ./core.dump

# Optional: copy private PDBs to ./symbols/
cp /path/to/MyApp.pdb        ./symbols/
cp /path/to/MyLibrary.pdb    ./symbols/
```

The `symbols/` directory is already in `.gitignore` (except the `.keep` placeholder).
Put as many PDBs here as needed; they are baked into the image alongside the dump.

To check the dump architecture before building (no tools required beyond `file`):
```sh
file core.dump
# Output includes: "ELF 64-bit LSB core file, x86-64" or "ARM aarch64"
```

---

## Step 2 — Build the analysis image

```sh
# Build (identical command on Windows, Linux, macOS including Apple Silicon)
docker compose build

# Start the container
docker compose up -d
```

Build time is typically 3–8 minutes depending on network speed and host platform.
Apple Silicon running x64 emulated will be slower on first build.

The build:
1. Installs the newest .NET SDK, diagnostic tools, and PowerShell (`pwsh`,
   as a .NET global tool) — no version pins — plus `dotnet-monitor` at a
   pinned version (installed for ad-hoc use, not run as a service).
2. Downloads the file server binary and the `fresh` terminal editor
   (pinned, static musl, sha256-verified) matching your platform.
3. Runs a toolchain smoke test (fails fast if packages are broken, incl.
   `pwsh`, `dotnet-monitor`, `fresh`, and `btop`).
4. Fetches the **exact DAC** for your dump's runtime from the Microsoft symbol
   server, keyed by the runtime module's build-ID [[³]](#references).
5. Runs the automated `dotnet-dump` analysis.
6. Produces a synthesized triage summary + full SOS output in `analysis.txt`.

### Build arguments

```sh
# Non-default dump filename
docker compose build --build-arg DUMP_FILE=myapp.dump

# ARM64 dump (Graviton / ARM Linux prod)
docker compose build --build-arg DUMP_ARCH=arm64

# Deeper wrapped-inner-exception unwinding (default 9; 0 disables).
# Raise for deeply-nested chains (each pass reloads the dump).
docker compose build --build-arg INNER_EXCEPTION_DEPTH=20

# Pin exact versions for reproducibility (see provenance.txt after first build)
docker compose build \
    --build-arg DOTNET_SDK_IMAGE="mcr.microsoft.com/dotnet/sdk:10.0@sha256:<digest>" \
    --build-arg FILESERVER_VERSION=v2026.2.515

# End-to-end smoke test (proves the whole toolchain works; adds ~60 s)
docker compose build --build-arg SMOKE_TEST=1
```

---

## Step 3 — Read the automated analysis

Open a browser and navigate to:
```
http://localhost:5550/
```

Two files are produced side by side in `/analysis/`:

- **`analysis.md`** — the friendly **rendered** view. The file server
  renders Markdown to HTML (Markdig); it has an H1 status line, a clickable
  table of contents, a Provenance table, the auto-triage sections, and the
  full SOS output split per command. Open this first. Append `?raw=1` to the
  URL to see the raw Markdown instead.
- **`analysis.txt`** — the **authoritative raw source**. `analysis.md` is a
  generated view of it; all tooling (`smoke.sh`, `rot-check`, `status.json`)
  asserts on `analysis.txt`. If the two ever disagree, trust the `.txt`.
  (Dump-derived text is always inside fenced code blocks in the `.md` — the
  renderer does not sanitize HTML, so this is deliberate and load-bearing.)

`analysis.txt` is structured as follows:

```
# Provenance                          ← build environment record
  base_image_tag, tool versions,
  dump SHA-256, runtime version, …

╔══════════════════════════╗
║   AUTO-TRIAGE SUMMARY    ║          ← synthesized quick-read
╚══════════════════════════╝
  TOP EXCEPTION
  FAULTING THREAD
  FIRST MANAGED CALL STACK
  HEURISTIC WARNINGS        ← deadlock, threadpool starvation, OOM, finalizer backlog
  TOP HEAP TYPES

═══════════════════════════
  FULL SOS OUTPUT FOLLOWS   ← raw dotnet-dump output for each command
═══════════════════════════
  runtimes, clrmodules, clrthreads, parallelstacks,
  clrstack -all, printexception -nested, finalizequeue,
  threadpool, syncblk, eeheap -gc, dumpheap -stat,
  analyzeoom
```

Start with the **AUTO-TRIAGE SUMMARY** — it tells you the exception type,
faulting thread, and any heuristic warnings in a glanceable format.

If the dump is low-fidelity (mini/triage/gcore, or otherwise missing the
managed runtime), `analysis.txt` opens with a prominent **`ANALYSIS DEGRADED`**
banner explaining what failed and how to re-capture a full dump.

A machine-readable `status.json` is written alongside `analysis.txt`
(`status`: `success` | `partial` | `failed`, plus detected runtime, arch,
fidelity, DAC source). The container's `HEALTHCHECK` and the entrypoint banner
surface it; `smoke.sh` / `rot-check.yml` assert on it.

---

## Step 4 — Dive deeper interactively

Open an interactive shell inside the running container:

```sh
docker exec -it dotnet-autopsy-sos bash
```

The shell prints a MOTD with a command reference. Use the `delve` wrapper for
a pre-configured `dotnet-dump analyze` session:

```sh
delve
```

This drops you into `dotnet-dump analyze` with symbol paths already configured.
Type SOS commands at the `>` prompt. See [SOS cheat-sheet](#sos-command-cheat-sheet) below.

`delve` (`dotnet-dump analyze`) is the simplest managed-analysis path and
needs no application binary — it locates the runtime via createdump's embedded
diagnostic header. Use it for most cases.

### lldb + SOS — use the `delve-lldb` wrapper

lldb + SOS **does** work for managed analysis (`clrthreads`, `clrstack`, `pe`,
…). The one requirement is the same as for any core file with gdb: **lldb
needs the executable that produced the dump.** A bare `lldb -c <dump>` fails
with `the target has no associated executable images`, and SOS then reports
`Failed to find runtime module (libcoreclr.so), 0x80004002`. Given the right
executable, lldb reconstructs the module list (incl. `libcoreclr.so`) and SOS
binds the DAC normally.

The `delve-lldb` wrapper handles this for you — it reads the executable path
the core records (`execfn`) and anchors lldb with it:

```sh
delve-lldb            # opens lldb+SOS on the baked dump
(lldb) clrthreads
(lldb) clrstack
(lldb) pe
```

- **Framework-dependent apps** (run as `dotnet YourApp.dll`): the recorded
  executable is `/usr/bin/dotnet`, which is already in the image — `delve-lldb`
  works with **no extra input**.
- **Self-contained / apphost apps** (a native launcher like `./YourApp`): copy
  that app binary into `./symbols/` before building (it is baked to
  `/symbols-user`); `delve-lldb` finds it by name. Without it, `delve-lldb`
  prints exactly what to supply, and `delve` still works in the meantime.

For native/ELF triage with no DAC and no executable, use elfutils — it reads
the core's notes directly (bare `lldb -c <dump>` cannot: it reports "no
associated executable images"):
```sh
eu-unstrip -n --core /analysis/core.dump      # modules + build-IDs
eu-readelf -n /analysis/core.dump | head      # ELF notes / arch
```

### Scripting with PowerShell

`pwsh` (PowerShell, installed as a .NET global tool) is available for
automating triage — parsing `analysis.txt`, scripting repeated SOS runs, or
ad-hoc .NET expressions:

```sh
pwsh                                          # interactive shell
pwsh -NoProfile -c '(Get-Content /analysis/analysis.txt | Select-String "Exception type:")'
```

### Editing in the container

`fresh` (a real terminal editor, GPL-2.0, github.com/sinelaw/fresh) is on
`PATH` for SDK devs editing or repro'ing in an interactive session — far
better than `nano` for code:

```sh
fresh /symbols-user/MyApp/Program.cs          # edit a file
fresh --version
```

`nano` and `less` remain as minimal fallbacks.

`btop` is on `PATH` for watching CPU/RAM/process load during heavy
in-container work (analyzing a very large dump, repro builds); `top`/`ps`
(procps) are the minimal baseline. Note this is a post-mortem container — the
crashed app is not running here, so `btop` is for the *analysis* workload,
not the target.

---

## SOS command cheat-sheet

Run these at the prompt inside `delve` (`dotnet-dump analyze`) or `delve-lldb`
(lldb + SOS). Bare `lldb -c <dump>` won't work — use the `delve-lldb` wrapper;
see [Step 4](#step-4--dive-deeper-interactively).

### Thread & stack

| Command | What it shows |
|---|---|
| `clrthreads` | All managed threads with state (exception thrown, GC, waiting…) |
| `clrstack` | Managed call stack for the current thread |
| `clrstack -all` | Managed stacks for all threads |
| `parallelstacks` | Parallel-tasks stack tree view |
| `setthread <id>` | Switch to a thread by index |

### Exceptions

| Command | What it shows |
|---|---|
| `printexception` or `pe` | Current exception (type, message, stack) |
| `printexception -nested` | Exception chain including InnerExceptions |
| `clrthreads` | Threads with exceptions show `(+)` |

### Memory & heap

| Command | What it shows |
|---|---|
| `dumpheap -stat` | Managed heap: type counts and total sizes |
| `dumpheap -type System.String` | All instances of a specific type |
| `gcroot <address>` | GC root chain — what's keeping an object alive |
| `eeheap -gc` | GC heap segments, sizes, and generation boundaries |
| `analyzeoom` | Out-of-memory analysis |
| `dumpobj <address>` or `do` | Dump a managed object's fields |
| `dso` | Dump all stack objects |

### Synchronization

| Command | What it shows |
|---|---|
| `syncblk` | Monitor lock table — OwnedBy / Waiting threads |
| `threadpool` | ThreadPool queue depth, running/idle workers |
| `finalizequeue` | Finalizer queue backlog |

### Symbols & paths

| Command | What it shows |
|---|---|
| `setsymbolserver -ms` | Use Microsoft public symbol server |
| `setsymbolserver -ms -cache /analysis/symbols` | MS server with local cache |
| `setsymbolserver -directory /symbols-user` | Use directory of local PDBs/DAC |
| `setclrpath <dir>` | Point to a directory containing the DAC for non-MS runtimes |
| `runtimes` | Show which .NET runtime the dump is from |
| `clrmodules` | List all managed modules |

### Native / ELF (outside SOS)

```sh
# Module list + build-IDs (no DAC, no executable needed).
# NOTE: bare `lldb -c core.dump` cannot do this — it reports
# "the target has no associated executable images". Use elfutils:
eu-unstrip -n --core core.dump | head -30

# ELF architecture / OS note
file core.dump

# Grep for version banner
strings -a core.dump | grep "Microsoft.NETCore.App/"

# addr2line — resolve native address to source file+line
addr2line -e /path/to/native.so 0x1234abcd
```

---

## How to determine the runtime version of a dump

You normally don't need to — `dotnet-symbol` resolves the exact DAC by build-ID
automatically [[³]](#references). But if you need to know or verify:

**Method 1 — elfutils eu-unstrip (definitive, no DAC or executable needed):**
```sh
eu-unstrip -n --core core.dump | grep libcoreclr
# Output: <build-id> <path>  — the build-ID is what dotnet-symbol uses
```

**Method 2 — strings scan (quick and dirty):**
```sh
strings -a core.dump | grep -oE "Microsoft\.NETCore\.App/[0-9]+\.[0-9]+\.[0-9]+" | head -1
```

**Method 3 — after DAC is loaded:**
```sh
dotnet-dump analyze core.dump -c "runtimes" -c exit
```

> Note: `lldb -c core.dump -o "image list"` is **not** a reliable method —
> bare lldb reports "the target has no associated executable images" for
> createdump cores (it needs the executable; see Step 4 / `delve-lldb`).

---

## Troubleshooting

### "Can not load or initialize libmscordaccore.so"

The DAC doesn't match the dump's runtime. Causes and fixes:

1. **Architecture mismatch** — the most common cause when using Apple Silicon.
   Check `analysis.txt` header for the arch-mismatch banner. Fix:
   ```sh
   docker compose build --build-arg DUMP_ARCH=amd64   # for x64 dump
   ```

2. **Non-Microsoft runtime** (Red Hat, Canonical builds, etc.) — no DAC on the
   Microsoft symbol server. Supply the DAC manually:
   ```sh
   # Copy the matching libmscordaccore.so from the origin container
   cp libmscordaccore.so ./symbols/
   docker compose build
   # Inside the session:
   setclrpath /symbols-user
   ```

3. **Symbol server unavailable at build time** — check build log for
   "dotnet-symbol fetch failed". Pre-seed `./symbols/` and rebuild
   (see [Offline use](#offline-use-and-air-gapped-builds)).

### "UNKNOWN" for most type/function names

The dump was captured with `gdb`/`gcore` or as a mini dump without the managed
heap. Re-capture with `createdump --full` or `DOTNET_DbgMiniDumpType=4`.
See [Step 0](#step-0--capture-a-good-dump-at-the-origin).

### lldb: "no associated executable images" / "Failed to find runtime module (libcoreclr.so), 0x80004002"

You ran a bare `lldb -c <dump>` without the executable. lldb (like gdb) needs
the binary that produced the core to reconstruct its module list; without it
SOS has no `libcoreclr.so` to bind. This is **not** a DAC/symbol problem and
**not** an upstream SOS limitation — given the right executable, lldb + SOS
works fully.

Fix: use the **`delve-lldb`** wrapper, which anchors lldb with the executable
the core records (`execfn`):

- Framework-dependent apps (`dotnet YourApp.dll`): execfn is `/usr/bin/dotnet`,
  already in the image — `delve-lldb` just works.
- Apphost / self-contained apps: drop the app binary into `./symbols/` before
  building (baked to `/symbols-user`); `delve-lldb` finds it by name.

Or use `delve` (`dotnet-dump analyze`), which needs no executable at all.

### File server not reachable at http://localhost:5550/

```sh
docker compose logs sos               # service name in docker-compose.yml
docker inspect dotnet-autopsy-sos     # container name — check port binding
```

Ensure the port binds to `127.0.0.1` (security default). If running remotely,
use SSH port forwarding: `ssh -L 5550:localhost:5550 user@host`.

### Build fails with "binary not found in archive"

The file server archive structure changed. Pin a known good release:
```sh
docker compose build --build-arg FILESERVER_VERSION=v2026.2.515
```

---

## Platform — same commands on all OSes

The canonical command is identical on Windows, Linux, and macOS:

```sh
docker compose build && docker compose up -d
```

The `platform: linux/amd64` key in `docker-compose.yml` pins the image
architecture to the dump's architecture, not the host. This prevents Apple
Silicon from silently building an arm64 image that cannot analyze an x64
dump [[¹]](#references).

| Host OS | Required setup |
|---|---|
| Linux x64 | Nothing extra |
| Windows 10/11 | Docker Desktop with WSL2 backend |
| macOS Intel | Nothing extra |
| macOS Apple Silicon | Enable Rosetta emulation in Docker Desktop (Settings → General) |

**Apple Silicon note:** the build runs x64 under emulation, which is slower
but produces a correct image. Interactive sessions (`docker exec`) are also
emulated; `dotnet-dump` and `lldb` work correctly but may feel slower for large
dumps. Allocate ≥8 GB to the Docker Desktop VM.

---

## Offline use and air-gapped builds

The image is online at **build time** only (symbol fetch, file server download).
Once built, the container runs fully offline.

**Air-gapped build** (no internet at build time):

1. Pre-seed the symbol cache with the matching DAC:
   ```sh
   # On a machine WITH network access:
   dotnet-symbol --microsoft-symbol-server --host-only --debugging core.dump \
       --symbols --modules --cache-directory ./symbols/
   ```

2. Build — `analyze.sh` detects the pre-seeded cache and skips the network fetch:
   ```sh
   docker compose build
   ```

---

## Reproducing a past case

Each image records exact tool versions + base image digest + dump SHA-256 in
`provenance.txt` (visible at the top of `analysis.txt`). To reproduce:

```sh
docker compose build \
    --build-arg DOTNET_SDK_IMAGE="mcr.microsoft.com/dotnet/sdk:10.0@sha256:<digest-from-provenance>" \
    --build-arg FILESERVER_VERSION=v2026.2.515   # from provenance
```

---

## Manually testing a release

When iterating on the image itself (a new feature/version), do an interactive
acceptance pass: build from a *real* dump and browse the rendered report and
welcome screen yourself. `demo.sh` does exactly this and leaves the container
running (contrast: `smoke.sh` is a self-cleaning pass/fail test; `rot-check`
is CI).

```sh
./demo.sh
```

It is self-contained and OS-agnostic — it generates its own content-rich,
throwaway Linux .NET dump inside a disposable SDK container (no real dump or
host .NET needed; the synthetic dump is `*.dump`-gitignored and removed after
it is baked in), builds, and starts a persistent container. It is idempotent:
re-run after each change and it replaces the previous demo.

Then:

- Rendered report : <http://localhost:5550/analysis/analysis.md>
- Raw / source    : `…/analysis.txt`  (or `…/analysis.md?raw=1`)
- Welcome screen  : `docker exec -it dotnet-autopsy-demo-sos bash`
- Interactive SOS : `docker exec -it dotnet-autopsy-demo-sos delve`
- Survive reboots : `./demo.sh --restart`  (adds `--restart unless-stopped`)
- Tear down       : `docker rm -f dotnet-autopsy-demo-sos && docker rmi dotnet-autopsy-demo-sos`

Good per-release checklist: `status=success`; `analysis.md` opens with the
H1/TOC and has per-command SOS sections; the welcome MOTD looks right;
`delve` → `clrthreads` works.

---

## Lifecycle and cleanup

Each analysis is a disposable per-case image. When done:

```sh
docker compose down                # stop and remove container
docker rmi dotnet-autopsy-sos      # remove image
docker image prune -f              # clean up dangling layers
```

The symbol cache (baked into the image) and dump (gitignored) do not need
separate cleanup.

---

## Extending the report tools (.NET 10 file-based apps)

The report logic is three **.NET 10 file-based apps** at the repo root —
`triage_summary.cs` (the triage section concatenated into the authoritative
`analysis.txt`), `analysis_md.cs` (the rendered `analysis.md`), and
`json-get.cs` (the `status.json` reader used by `entrypoint.sh` /
`demo.sh` / `smoke.sh` / `rot-check.yml`). They are **BCL-only** (no NuGet,
no `.csproj`) so they build offline, and they are byte-for-byte ports of the
former Python scripts. `parity/run-parity.sh` is the differential gate:
add a fixture under `parity/fixtures/` and keep every fixture byte-identical.

### ⚠ Gotcha: `dotnet publish file.cs` defaults to NativeAOT in .NET 10

For a **file-based app**, `dotnet publish app.cs` implicitly sets
`PublishAot=true`. NativeAOT needs a C toolchain (`clang`/`gcc`), which the
.NET SDK image does **not** include, so a naïve publish fails with:

```
error : Platform linker ('clang' or 'gcc') not found in PATH.
Ensure you have all the required prerequisites … nativeaot-prerequisites
```

The convention in this repo (used in the `common/base.dockerfile` toolchain
publish step **and** `common/parity/run-parity.sh`) is a framework-dependent build
with AOT and single-file disabled — the runtime is present at run time
because the analysis stage is `FROM` the SDK toolchain:

```sh
dotnet publish <app>.cs -c Release -o /opt/report-bin/<app> \
    -p:PublishAot=false -p:PublishSingleFile=false --self-contained false
```

The apphost lands at `/opt/report-bin/<app>/<app>`.

### Why pre-published, not `dotnet run app.cs`

`dotnet run app.cs` recompiles on first run, needs NuGet/network each
invocation, and **on failure prints build/restore text to stdout** — which
would corrupt `analysis.txt` (triage stdout is concatenated raw). So the
apps are compiled **once** in the cached toolchain layer to fixed binaries
with pristine stdout; per-case `analyze.sh` just runs the binary.

### Adding another file-based app

Keep it BCL-only (offline-safe); write the source **ASCII-only**, emitting
any non-ASCII via `\uXXXX` escapes (so the file can't be mangled in transit
and the emitted bytes are exact — `U+2028`/`U+2029` as literals are C# line
terminators and will break the lexer); add it to the Dockerfile `COPY` +
publish loop; if it transforms input deterministically, add a
`parity/fixtures/` case and run `bash common/parity/run-parity.sh sos`
until byte-identical.

### Parity discipline

The sos image uniquely has a **dual history**: it was first parsed by
Python (`triage_summary.py`, `analysis_md.py`), then byte-for-byte ported
to .NET 10 file-based apps. While the `.py` oracles existed on the branch,
parity ran in `ORACLE` mode (`python3 <oracle>` vs the .NET binary,
`cmp` per fixture). After sign-off the oracles were deleted; the gate
now runs in `GOLDEN` mode against `sos/parity/golden/*` — the captured
oracle output frozen in the repo. **Any drift fails the gate**; intentional
behavior changes update both code and golden in the same commit. Re-seed
only when the drift is verified correct:

```sh
bash common/parity/run-parity.sh sos --seed-golden   # capture new baseline
```

The trace and gcdump siblings followed a different path: they never had
a Python oracle, so their goldens were seeded from the first
verified-correct .NET run. From then on the discipline is identical —
strict regression gate, re-seed only with justification. See the
top-level `README.md` § *Parity gate* for the full directory contract.

---

## References

1. [SOS debugging extension — DAC must match runtime & arch](https://github.com/dotnet/diagnostics/blob/main/documentation/FAQ.md)
2. [Docker multi-platform & Apple Silicon Rosetta](https://docs.docker.com/build/building/multi-platform/)
3. [dotnet-symbol — downloads DAC/DBI/symbols matched by build-ID](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-symbol)
4. [dotnet-dump — version matching, setclrpath, interactive commands](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-dump)
5. [Debug Linux dumps — full workflow](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/debug-linux-dumps)
6. [.NET dumps FAQ — createdump, dump types, fidelity](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/faq-dumps)
7. [Collect dumps on crash — DOTNET_DbgEnableMiniDump](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/collect-dumps-crash)
8. [SOS commands reference](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/sos-debugging-extension)
9. [lldb debugger](https://lldb.llvm.org/)
10. [File server releases (per-RID assets)](https://github.com/JanusMael/Bennewitz.Ninja.FileServer/releases)
