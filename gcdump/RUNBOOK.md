# Runbook — analyzing a `.gcdump` with `dotnet-autopsy/gcdump`

`dotnet-autopsy/gcdump` is the **managed-heap** triage sibling of
`dotnet-autopsy/sos` (crash post-mortem) and `dotnet-autopsy/trace`
(CPU/perf post-mortem). It bakes a `dotnet-gcdump` capture (`.gcdump`) into
the image, runs an automated heap analysis at build time, then stays alive
as a web file server so you can browse the rendered report and pull the
raw `dotnet-gcdump report` text.

**What it answers:** *"Which types are eating my managed heap?"* —
top-types-by-size ranking, instance counts, retained-bytes totals, and a
small set of heuristic warnings (dominant single type, top-3 concentration,
suspiciously high string/byte[] share). Use it alongside the sos image
when you suspect a leak or unbounded growth.

**Why this image (vs. SOS).** SOS's `dumpheap -stat` gives you the same
top-types view from a **core dump**, but you don't always have (or want)
a full core: it requires a SIGABRT/SIGSEGV or `dotnet-dump collect`, is
large, and contains process memory you may not want to ship around.
`.gcdump` is the **cheap, narrow** alternative — it's a managed-heap
snapshot (~MB, not GB) you can collect from a healthy live process and
move around freely.

---

## Prerequisites

- Docker (with BuildKit; default in recent versions).
- A `.gcdump` capture you want to analyze. Don't have one? See
  [Capturing a usable .gcdump](#capturing-a-usable-gcdump) below.

---

## Step 0 — Capturing a usable `.gcdump`

The cheapest capture is on the source machine, against a **healthy live
process** (no crash needed):

```sh
# Attach to a running process by PID (the usual production case)
dotnet-gcdump collect -p <pid> -o heap.gcdump

# List traceable .NET processes if you don't know the PID
dotnet-gcdump ps
```

`dotnet-gcdump` triggers a managed GC inside the target process and then
serializes the live-object graph; the target process pauses briefly during
collection and resumes normally afterwards. The output is a self-contained
`.gcdump` file, typically a few MB to a few hundred MB depending on heap
size.

A usable `.gcdump` should be **at least a few KB**; a smaller file usually
means the collection failed (process exited, no permission, wrong PID).
The image will mark `status=failed` (with an `⚠ ANALYSIS DEGRADED` banner)
if `dotnet-gcdump report` cannot parse the file.

---

## Step 1 — Prepare inputs

```sh
# Copy the .gcdump to the repo root (the default filename is heap.gcdump)
cp /path/to/heap.gcdump ./heap.gcdump
```

That's it — there are **no DAC/symbol gymnastics** for gcdumps, unlike the
sos sibling. Managed type names are recorded directly in the file format,
so the analysis needs no symbol server.

---

## Step 2 — Build the analysis image

```sh
# Identical command on Windows, Linux, macOS (incl. Apple Silicon)
docker compose --profile gcdump build gcdump
docker compose --profile gcdump up    -d gcdump
```

…or via the thin wrappers:

```sh
./build.sh gcdump                                          # builds base then gcdump
./build.sh gcdump --build-arg GCDUMP_FILE=myheap.gcdump
./demo.sh  gcdump                                          # persistent, idempotent
```

The build first builds the shared `dotnet-autopsy-base` (cached across all
three siblings; only one cold build per machine), then the per-case gcdump
image on top.

### Build arguments

```sh
# Non-default gcdump filename
docker compose --profile gcdump build gcdump --build-arg GCDUMP_FILE=myheap.gcdump

# In-image end-to-end smoke (synthesizes a tiny .gcdump at build time;
# proves the whole gcdump chain works; adds ~30-60 s)
docker compose --profile gcdump build gcdump --build-arg SMOKE_TEST=1
```

---

## Step 3 — Read the automated analysis

Open `http://localhost:5550/`. The starting URLs are listed on the welcome
screen / MOTD inside the container; the highlights:

| URL | What |
|---|---|
| `/analysis/analysis.md` | **Rendered report** — start here (navigable TOC). |
| `/analysis/analysis.txt` | Authoritative raw source (tooling asserts on it). |
| `/analysis/heap.gcdump` | The raw `.gcdump` (re-analyze locally with your own tools). |
| `/analysis/status.json` | Machine status: `success` / `partial` / `failed`. |
| `/analysis/sources/` | The standalone-reusable .NET 10 report apps (`json-get.cs`, `analysis_md.cs`, `gcdump_triage.cs`) + their reuse README. |
| `/analysis/docs/RUNBOOK.md` | This document, rendered. |

The triage block at the top of `analysis.md` has three sections:

- **HEAP SUMMARY** — total live objects, total size, and dotnet-gcdump
  report header info parsed from the `=== dotnet-gcdump report` block.
- **TOP TYPES BY SIZE** — rank · type · count · size in bytes (top 25)
  derived from `dotnet-gcdump report` parsed by `gcdump_triage.cs`.
- **HEURISTIC WARNINGS** — flags like *Dominant type: System.String at
  41% of heap* and *Top 3 types account for 78% of heap*. Hints, not
  conclusions.
- **(Full dotnet-gcdump report)** — the raw `dotnet-gcdump report` text
  the synthesis is built from, fenced.

---

## Step 4 — Dive deeper interactively

```sh
docker exec -it dotnet-autopsy-gcdump bash
```

Once inside, the gcdump lives at `$CASE_GCDUMP`. The most useful next steps:

```sh
# Re-run the report (full output, no top-N truncation)
dotnet-gcdump report "$CASE_GCDUMP"

# Pipe to grep / awk to slice a specific type
dotnet-gcdump report "$CASE_GCDUMP" | grep -E 'MyApp\.|System\.String'

# PowerShell helpers (installed; useful for parsing analysis.txt)
pwsh -NoProfile -Command 'Get-Content /analysis/analysis.txt | Select-String "bytes="'
```

`dotnet-counters` and `dotnet-trace` are also installed — useful when you
want to look at allocations from a *live* process from this container
(rare; this is a post-mortem image).

---

## `dotnet-gcdump` cheat-sheet

| Command | What |
|---|---|
| `dotnet-gcdump ps` | List traceable .NET processes. |
| `dotnet-gcdump collect -p <pid> -o heap.gcdump` | Attach + snapshot a live process's managed heap. |
| `dotnet-gcdump report <file>` | Print top-types-by-size text report (the v1 input). |
| `dotnet-gcdump report <file> -t <type-id>` | Drill into a specific type ID for refs/retainers. |

> The full schema lives at <https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-gcdump>.

---

## Troubleshooting

### `status=failed` after the build

Open `/analysis/analysis.txt` and look at the `⚠ ANALYSIS DEGRADED` banner.
The most common causes are: empty / aborted capture, wrong process (the
target wasn't .NET 5+ with `EnableDiagnostics`), or a corrupted `.gcdump`.
Re-capture and rebuild.

### No `TOP TYPES BY SIZE` rows

Either the capture finished but contained an empty heap (target had just
been started / GC'd everything) or the `.gcdump` is malformed. The Full
dotnet-gcdump report section will usually surface the underlying parser
error.

### Capture failed with `process is not running .NET 5+` or `cannot connect`

Older .NET runtimes (Core 3.1 and earlier) don't ship the EventPipe APIs
`dotnet-gcdump` requires. Upgrade or fall back to a core dump + sos
analysis.

---

## Extending the report tools (.NET 10 file-based apps)

`gcdump_triage.cs` is one of four BCL-only .NET 10 **file-based apps**
shipped by this family (the others are `analysis_md.cs` and `json-get.cs`
in the shared base, plus the per-image `triage_summary.cs` and the
csproj-based `TraceTriage`). The same convention and the **NativeAOT-publish
gotcha** documented in **`sos/RUNBOOK.md` § "Extending the report tools"**
apply here verbatim; that section is the authoritative reference for
adding more file-based apps. Don't reinvent the publish command — copy
the framework-dependent flags exactly.

### Parity discipline (gcdump is GOLDEN-only)

Gcdump never had a Python oracle, so `gcdump/parity/golden/*` was
captured from the first verified-correct run via
`bash common/parity/run-parity.sh gcdump --seed-golden`. From then on
it is a strict regression gate: any change to `gcdump_triage.cs` (or
`common/analysis_md.cs`, or `common/json-get.cs`) that drifts a golden
fails the gate. Re-seed only when the drift is intentional and the new
output has been manually verified. See the top-level `README.md` §
*Parity gate* for the full contract.

---

## Platform — same commands on all OSes

Identical to the sos sibling — see `sos/RUNBOOK.md` § *Platform*. Gcdumps
are **not DAC-gated** (the type-name table is part of the file format), so
unlike sos there's no arch-mismatch failure mode. `DUMP_ARCH=amd64` is the
default and matches most production captures; switch to `arm64` only for
image-family consistency if your producers are arm64.

---

## Lifecycle and cleanup

```sh
docker rm  -f dotnet-autopsy-gcdump  2>/dev/null
docker rmi -f dotnet-autopsy-gcdump  2>/dev/null
docker image prune -f
```

The shared `dotnet-autopsy-base` is intentionally left behind — it's the
cached toolchain all three siblings reuse.
