# Runbook — analyzing a `.nettrace` with `dotnet-autopsy/trace`

`dotnet-autopsy/trace` is the perf-triage sibling of `dotnet-autopsy/sos`.
It bakes a `dotnet-trace` capture (`.nettrace`) into the image, runs an
automated analysis at build time, then stays alive as a web file server so
you can browse the rendered report and (optionally) pull the speedscope
JSON for a flame-graph view.

**What gets synthesized:** top-CPU function ranking from
`dotnet-trace report topN` + trace metadata + runtime probe (CLR version
detected from the `RuntimeStart` event) + GC summary (gen0/1/2/LOH counts
and average pause durations from paired `GCStart`/`GCStop` events) +
exception counts (top 10 by `ExceptionStart`) + heuristic flags
(single-function hotspot, concentrated CPU). The runtime/GC/exception
sections are parsed via `Microsoft.Diagnostics.Tracing.TraceEvent` —
the only NuGet dependency in this family. The full `dotnet-trace report`
text and a speedscope-app folded-stack JSON are always written, so flame
graphs and one-off custom analyses are one click (or one `docker exec`)
away.

**Not yet:** allocation-by-type, lock-contention histograms, and
thread-pool starvation timelines. Those exist in the captured
`.nettrace` (the speedscope JSON exposes them) but aren't synthesized
into the auto-triage section yet.

---

## Prerequisites

- Docker (with BuildKit; default in recent versions).
- A `.nettrace` capture you want to analyze. Don't have one? See
  [Capturing a usable .nettrace](#capturing-a-usable-nettrace) below.

---

## Step 0 — Capturing a usable `.nettrace`

The cheapest capture is on the source machine, with the **default
`cpu-sampling` profile**, for a short window during the slow period:

```sh
# Attach to a running process (the usual production case)
dotnet-trace collect --format nettrace -o trace.nettrace -p <pid>
# stop with Ctrl-C when you've captured the window you want

# Or trace a one-shot command from start to exit
dotnet-trace collect --format nettrace -o trace.nettrace -- <command>
```

The default profile is `cpu-sampling`. The auto-triage uses TraceEvent
to read GC pairs + exception starts + the runtime version from whatever
events the capture contains, so even a default `cpu-sampling` capture
fills in the GC / exception sections (the runtime emits a small number
of GC events regardless of profile). Richer profiles (`gc-verbose`,
`gc-collect`, custom EventSources) get fully forwarded into the
speedscope JSON for deeper offline analysis.

The trace file should be **at least a few KB**; a very small file usually
means an empty/aborted capture or the wrong tool. The image will mark
`status=failed` (with an `⚠ ANALYSIS DEGRADED` banner) if `dotnet-trace
report` cannot find any topN block.

---

## Step 1 — Prepare inputs

```sh
# Copy the .nettrace to the repo root (the default filename is trace.nettrace)
cp /path/to/trace.nettrace ./trace.nettrace
```

That's it — there are **no DAC/symbol gymnastics** for traces, unlike the
sos sibling. Managed method names are recorded in the trace itself
(EventPipe rundown), so the v1 analysis needs no symbol server.

---

## Step 2 — Build the analysis image

```sh
# Identical command on Windows, Linux, macOS (incl. Apple Silicon)
docker compose --profile trace build trace
docker compose --profile trace up    -d trace
```

…or via the thin wrappers:

```sh
./build.sh trace                                       # builds base then trace
./build.sh trace --build-arg TRACE_FILE=mytrace.nettrace
./demo.sh  trace                                        # persistent, idempotent
```

The build first builds the shared `dotnet-autopsy-base` (cached across both
siblings; only one cold build per machine), then the per-case trace image
on top.

### Build arguments

```sh
# Non-default trace filename
docker compose --profile trace build trace --build-arg TRACE_FILE=mytrace.nettrace

# In-image end-to-end smoke (synthesizes a tiny .nettrace at build time;
# proves the whole trace chain works; adds ~60-90 s)
docker compose --profile trace build trace --build-arg SMOKE_TEST=1
```

---

## Step 3 — Read the automated analysis

Open `http://localhost:5550/`. The starting URLs are listed on the welcome
screen / MOTD inside the container; the highlights:

| URL | What |
|---|---|
| `/analysis/analysis.md` | **Rendered report** — start here (navigable TOC). |
| `/analysis/analysis.txt` | Authoritative raw source (tooling asserts on it). |
| `/analysis/trace.speedscope.json` | Drop this URL into <https://www.speedscope.app/> for a real flame graph. |
| `/analysis/status.json` | Machine status: `success` / `partial` / `failed`. |
| `/analysis/sources/` | The standalone-reusable .NET 10 report apps (`json-get.cs`, `analysis_md.cs`, `trace_triage.cs`) + their reuse README. |
| `/analysis/docs/RUNBOOK.md` | This document, rendered. |

The triage block at the top of `analysis.md` synthesizes these sections:

- **TOP CPU FUNCTIONS** — rank · function · inclusive% · exclusive%
  (parsed from `dotnet-trace report topN -n 25`).
- **TRACE METADATA** — trace file path + size, sample count and duration
  derived from the speedscope JSON.
- **GC SUMMARY** — counts and average pause durations per generation
  (gen0/1/2/LOH) from paired `GCStart`/`GCStop` events (TraceEvent).
  Only emitted when the capture contains those events.
- **EXCEPTION COUNTS (top 10)** — frequency of `ExceptionStart` events
  grouped by exception type (TraceEvent). Only emitted when present.
- **HEURISTIC WARNINGS** — flags like *Single-function hotspot: foo at
  73.5% exclusive CPU* and *Highly concentrated CPU: top 3 functions =
  92.4% exclusive*. Hints, not conclusions.
- **(Full trace tool output)** — the raw `dotnet-trace report` / `convert`
  text the synthesis is built from, fenced beneath the
  `FULL TRACE OUTPUT FOLLOWS` divider.

---

## Step 4 — Dive deeper interactively

```sh
docker exec -it dotnet-autopsy-trace bash
```

Once inside, the trace lives at `$CASE_TRACE`. The most useful next steps:

```sh
# Re-run topN with a different N or against a different trace
dotnet-trace report "$CASE_TRACE" topN -n 50

# Produce a folded-stack JSON for https://www.speedscope.app/
dotnet-trace convert "$CASE_TRACE" --format speedscope -o /tmp/t
ls /tmp/t.speedscope.json     # NOTE: -o is a BASENAME; .speedscope.json is appended

# A different format if you prefer Chromium devtools:
dotnet-trace convert "$CASE_TRACE" --format chromium -o /tmp/t

# PowerShell helpers (installed; useful for parsing analysis.txt)
pwsh -NoProfile -Command 'Get-Content /analysis/analysis.txt | Select-String "▸"'
```

`dotnet-counters` is also installed — useful when you want to attach to a
*live* process from this container (rare; this is a post-mortem image).

---

## `dotnet-trace` cheat-sheet

| Command | What |
|---|---|
| `dotnet-trace collect -- <cmd>` | Run + trace `<cmd>` until it exits. |
| `dotnet-trace collect -p <pid>` | Attach to a live process. Ctrl-C to stop. |
| `dotnet-trace collect --profile gc-verbose -- <cmd>` | Switch profile (cpu-sampling default). |
| `dotnet-trace ps` | List traceable .NET processes. |
| `dotnet-trace report <file> topN` | Top-N methods (BCL-friendly text). |
| `dotnet-trace convert <file> --format speedscope -o <BASE>` | Folded-stack JSON for speedscope.app. |
| `dotnet-trace convert <file> --format chromium -o <BASE>`   | Chromium devtools profile JSON. |

---

## Troubleshooting

### `status=failed` after the build

Open `/analysis/analysis.txt` and look at the `⚠ ANALYSIS DEGRADED` banner.
The most common causes are: empty / aborted capture, wrong profile (no
cpu-sampling events), or a corrupted `.nettrace`. Re-capture and rebuild.

### No `TOP CPU FUNCTIONS` rows

Either the capture didn't contain CPU samples (wrong profile) or the
workload was idle. Re-capture during the slow window with the default
`--profile cpu-sampling`.

### The speedscope file is named `*.speedscope.json`, not the `-o` value

That's a known `dotnet-trace convert` behavior — `-o BASE` is treated as a
basename and `.speedscope.json` is appended. `analyze-trace.sh` and
`dotnet-autopsy-trace`'s MOTD both already account for this.

---

## Extending the report tools

The trace triage app is the **one exception** to the family's BCL-only /
file-based-app rule: it lives at `trace/TraceTriage/` as a `.csproj`
project because it pulls in **`Microsoft.Diagnostics.Tracing.TraceEvent`**
(the only NuGet dependency in the family), which is what lets it walk
the EventPipe stream for runtime version, GC pairs, and exception starts.
All other report apps in the family — `analysis_md.cs`, `json-get.cs`,
`sos/triage_summary.cs`, `gcdump/gcdump_triage.cs` — are BCL-only .NET 10
**file-based apps** (`.cs` directly publishable, no `.csproj`).

The same **NativeAOT-publish gotcha** documented in **`sos/RUNBOOK.md` §
"Extending the report tools"** applies to both forms — framework-dependent,
AOT-off, single-file-off. The Dockerfile's `dotnet publish` step uses
those exact flags; copy them when adding a new app.

### Parity discipline (trace is GOLDEN-only)

Trace never had a Python oracle (TraceEvent has no Python equivalent at
this depth), so `trace/parity/golden/*` was captured from the
first verified-correct run via `bash common/parity/run-parity.sh trace
--seed-golden`. From then on it is a strict regression gate: any change
to `TraceTriage/Program.cs` (or `common/analysis_md.cs`, or
`common/json-get.cs`) that drifts a golden fails the gate. Re-seed only
when the drift is intentional and the new output has been manually
verified. See the top-level `README.md` § *Parity gate* for the full
contract.

---

## Platform — same commands on all OSes

Identical to the sos sibling — see `sos/RUNBOOK.md` § *Platform*. Traces
are not DAC-gated, so on Apple Silicon you can build native arm64 if your
trace was captured on arm64; otherwise `DUMP_ARCH=amd64` (default) works
under Rosetta/QEMU. The compose `--profile trace` switch ensures sos and
trace don't accidentally both try to bind :5550.

---

## Lifecycle and cleanup

```sh
docker rm  -f dotnet-autopsy-trace  2>/dev/null
docker rmi -f dotnet-autopsy-trace  2>/dev/null
docker image prune -f
```

The shared `dotnet-autopsy-base` is intentionally left behind — it's the
cached toolchain both siblings reuse.
