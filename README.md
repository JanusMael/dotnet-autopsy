# dotnet-autopsy — forensic post-mortem analysis of .NET diagnostic artifacts

[![CI — parity gate](https://github.com/JanusMael/dotnet-autopsy/actions/workflows/ci.yml/badge.svg)](https://github.com/JanusMael/dotnet-autopsy/actions/workflows/ci.yml)
[![Rot-check](https://github.com/JanusMael/dotnet-autopsy/actions/workflows/rot-check.yml/badge.svg)](https://github.com/JanusMael/dotnet-autopsy/actions/workflows/rot-check.yml)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Base image](https://ghcr-badge.egpl.dev/janusmael/dotnet-autopsy-base/latest_tag?label=base)](https://github.com/JanusMael/dotnet-autopsy/pkgs/container/dotnet-autopsy-base)
[![Sponsor](https://img.shields.io/static/v1?label=Sponsor&message=%E2%9D%A4&logo=GitHub&color=%23fe8e86)](https://github.com/sponsors/JanusMael)

A family of self-contained Docker images that each bake in a captured .NET
diagnostic artifact, run an automated analysis at build time, then stay alive
as a web file server so you can browse the rendered report and dive deeper
interactively. One toolchain, one shared base, three per-artifact siblings:

| Image                     | Artifact          | What it answers                                | Status  |
|---------------------------|-------------------|------------------------------------------------|---------|
| `dotnet-autopsy/sos`      | Linux .NET **core dump** (`.dump`)        | *Why did it crash / deadlock?* Exception chain, faulting thread, managed call stacks, top heap types, SOS interactive. | shipping |
| `dotnet-autopsy/trace`    | `dotnet-trace` capture (`.nettrace`)      | *Why is it slow?* Top CPU functions, GC summary, exception counts (via TraceEvent), basic trace metadata + heuristic flags. | shipping |
| `dotnet-autopsy/gcdump`   | `dotnet-gcdump` heap snapshot (`.gcdump`) | *Where is memory going?* Top types by size, heap summary, dominator heuristics (parses `dotnet-gcdump report`). | shipping |

The shared toolchain (.NET SDK, all dotnet-* diagnostic tools, `pwsh`, the
file server, the three reusable report apps) is the cached
**`dotnet-autopsy-base`** image; each sibling is a thin `FROM` of that base
plus the artifact-specific analysis. The same `analysis.md` rendering,
`json-get` status reader, parity GOLDEN gate, and MOTD/sources scaffolding
are shared across the family.

**Base image flavors:** Microsoft's .NET SDK image (`mcr.microsoft.com/dotnet/sdk:10.0`)
is the supported default — that's the path the parity GOLDEN gate covers.
The base is intentionally a swap point; see
[Adapting the base image](#adapting-the-base-image) for the general
approach and [Chainguard / Wolfi (supported automated adaptation)](#chainguard--wolfi-supported-automated-adaptation)
for the one shipped automation.

> **Security note:** every captured artifact contains process memory or
> stack samples — secrets, tokens, PII, internal call sites. Treat every
> image produced by this tool as a sensitive artifact. See
> [Security](#security) for controls.

A quick start for each sibling appears below — sos (Linux core dump),
then trace (`.nettrace`), then gcdump (`.gcdump`). Full per-sibling
docs live in **`sos/RUNBOOK.md`** (DAC/symbols, the SOS cheat-sheet,
interactive delving), **`trace/RUNBOOK.md`** (capturing a `.nettrace`,
TraceEvent depth, the dotnet-trace cheat-sheet), and
**`gcdump/RUNBOOK.md`** (capturing a `.gcdump`, the heap report,
re-running `dotnet-gcdump` interactively).

---

## Quick start (`dotnet-autopsy/sos`)

1. Copy your core dump to the repo root:
   ```sh
   cp /path/to/core.dump ./core.dump
   ```

2. (Optional) Drop private PDBs into `symbols/`:
   ```sh
   cp /path/to/MyApp.pdb ./symbols/
   ```

3. Build and start:
   ```sh
   # Identical command on Windows, Linux, and macOS (incl. Apple Silicon)
   docker compose build
   docker compose up -d
   ```

4. Open the results in a browser:
   ```
   http://localhost:5550/
   ```
   Open **`analysis/analysis.md`** for the rendered, navigable report
   (headings + table of contents; the server renders Markdown via Markdig).
   `analysis/analysis.txt` is the raw, authoritative source that tooling
   asserts on; append `?raw=1` to the `.md` URL to see its Markdown source.

5. To dive deeper interactively:
   ```sh
   docker exec -it dotnet-autopsy-sos bash
   delve          # dotnet-dump analyze (no app binary needed) — start here
   delve-lldb     # lldb + SOS (anchors lldb with the core's executable)
   ```
   Both give the same SOS commands (`clrthreads`, `clrstack`, `pe`, …).
   `delve` is simplest; `delve-lldb` is the native-lldb path — for
   self-contained/apphost apps, drop the app binary in `symbols/` first
   (framework-dependent `dotnet App.dll` dumps need nothing extra).

   **PowerShell** (`pwsh`) is also baked in for scripting triage/automation
   (e.g. `pwsh -c '...'` to post-process `analysis.txt`). **`dotnet-monitor`**
   is installed too (pinned) for ad-hoc use — it is *not* run as a service:
   this is a post-mortem dump container with no live target app, and
   dotnet-monitor cannot read a core file (that is `dotnet-dump`'s job).
   **`fresh`** (getfresh.dev / github.com/sinelaw/fresh, GPL-2.0) is a real
   terminal editor for devs editing/repro'ing with the in-container SDK —
   `nano` is kept only as a minimal fallback. **`btop`** is available for
   watching CPU/RAM during heavy in-container work (large-dump analysis,
   repro builds); `top`/`ps` (procps) remain as the minimal baseline.

---

## Quick start (`dotnet-autopsy/trace`)

1. Copy your `.nettrace` capture to the repo root:
   ```sh
   cp /path/to/trace.nettrace ./trace.nettrace
   ```
   No symbols or DAC needed — managed method names are baked into the
   trace itself via EventPipe rundown.

2. Build and start (trace is opt-in via `--profile` so it doesn't
   collide with the default `sos` service on port 5550):
   ```sh
   docker compose --profile trace build trace
   docker compose --profile trace up -d trace
   ```

   Or via the thin wrappers: `./build.sh trace` (CI-style) or
   `./demo.sh trace` (persistent + idempotent — uses a synthetic
   `.nettrace` if you don't have one to test with).

3. Open the results in a browser:
   ```
   http://localhost:5550/analysis/analysis.md
   ```
   Plus a **speedscope JSON** at
   `http://localhost:5550/analysis/trace.speedscope.json` — open in
   <https://www.speedscope.app/> for an interactive flame graph.
   `analysis.md` shows top CPU stacks, GC summary, exception counts,
   and runtime version (all via TraceEvent).

4. To dive deeper interactively:
   ```sh
   docker exec -it dotnet-autopsy-trace bash
   dotnet-trace report $CASE_TRACE topN -n 30
   dotnet-trace convert $CASE_TRACE --format speedscope
   ```

See **`trace/RUNBOOK.md`** for the full flow (capturing the trace at
the source, TraceEvent provider details, when GC pauses vs. exception
storms vs. thread-pool starvation point at different root causes).

---

## Quick start (`dotnet-autopsy/gcdump`)

1. Copy your `.gcdump` snapshot to the repo root:
   ```sh
   cp /path/to/heap.gcdump ./heap.gcdump
   ```
   Gcdumps are **architecture-portable** and need no DAC or symbols —
   the type-name table is part of the file format.

2. Build and start (gcdump is opt-in via `--profile`):
   ```sh
   docker compose --profile gcdump build gcdump
   docker compose --profile gcdump up -d gcdump
   ```

   Or `./build.sh gcdump` / `./demo.sh gcdump` (the demo generates a
   synthetic 68 MB heap if you don't have a `.gcdump` to test with).

3. Open the results in a browser:
   ```
   http://localhost:5550/analysis/analysis.md
   ```
   The **TOP TYPES BY SIZE** section ranks heap occupants by bytes — the
   first place to look when answering *"why is this process holding
   N GB of managed memory?"*.

4. To re-run the report interactively:
   ```sh
   docker exec -it dotnet-autopsy-gcdump bash
   dotnet-gcdump report $CASE_GCDUMP | head -30
   ```

See **`gcdump/RUNBOOK.md`** for the full flow (capturing a snapshot
from a live process via `dotnet-gcdump collect`, reading the heap
heuristics).

---

## Build arguments

| Arg | Default | Image | Purpose |
|---|---|---|---|
| `DUMP_FILE` | `core.dump` | sos | Core-dump filename in the repo root |
| `TRACE_FILE` | `trace.nettrace` | trace | `.nettrace` filename in the repo root |
| `GCDUMP_FILE` | `heap.gcdump` | gcdump | `.gcdump` filename in the repo root |
| `DUMP_ARCH` | `amd64` | all | Artifact CPU architecture: `amd64` or `arm64`. **Must match the artifact, not your laptop.** For trace and gcdump it's informational (those formats are portable); for sos it's a hard gate (DAC cannot cross-analyze). |
| `INNER_EXCEPTION_DEPTH` | `9` | sos | Max wrapped-inner-exception expansion passes (FailFast / `AggregateException` unwrap). Raise for deeply-nested chains; `0` disables. Each pass reloads the dump. |
| `DOTNET_SDK_IMAGE` | `mcr.microsoft.com/dotnet/sdk:10.0` | all | Base image. Override to match the artifact's OS (e.g. `…sdk:10.0-jammy`) |
| `FILESERVER_VERSION` | `latest` | all | File server release tag — pin for reproducibility (e.g. `v2026.2.515`) |
| `DOTNET_MONITOR_VERSION` | `9.0.0` | all | dotnet-monitor tool version — **pinned** (its release cadence is independent of the SDK; unpinned installs are unreliable) |
| `FRESH_VERSION` | `v0.3.6` | all | Fresh terminal-editor release tag — **pinned**, static musl binary fetched + sha256-verified at build |
| `SMOKE_TEST` | `0` | all | Set to `1` to run an end-to-end toolchain smoke test at build |

Example with custom args:
```sh
docker compose build \
    --build-arg DUMP_FILE=myapp.dump \
    --build-arg FILESERVER_VERSION=v2026.2.515

# or via build.sh / build.ps1:
./build.sh --build-arg DUMP_FILE=myapp.dump
.\build.ps1 -BuildArgs @("--build-arg", "DUMP_FILE=myapp.dump")
```

---

## Platform follows the dump, not your laptop

Core dumps are architecture-specific. SOS/DAC **cannot cross-analyze**
different architectures [[¹]](#references). The image platform is set to match
the **dump**, regardless of the build host.

| Host | Dump arch | What happens |
|---|---|---|
| Linux x64 | x64 (amd64) | Native build — fastest |
| Windows (WSL2) | x64 (amd64) | Native build |
| macOS Apple Silicon | **x64 (amd64)** | Emulated via QEMU/Rosetta — **slower, but correct** |
| macOS Apple Silicon | arm64 | Native (set `DUMP_ARCH=arm64`) |

**Apple Silicon tips:**
- Enable "Use Rosetta for x86/amd64 emulation" in Docker Desktop → Settings → General.
  This uses Apple's Rosetta translator instead of QEMU — significantly faster.
- Allocate ≥8 GB to the Docker Desktop VM (Settings → Resources) for large dumps.
- Expect the first build to take longer than on an x64 machine; analysis correctness
  is identical [[²]](#references).

---

## How the DAC is chosen

You do not need to know which .NET runtime produced the dump. `dotnet-symbol`
reads the **build-ID embedded in the dump's modules** and fetches the exact
matching `libmscordaccore.so` from the Microsoft symbol server [[³]](#references).
Build-ID matching is more precise than version-string correlation.

To verify which runtime a dump needs (no DAC, no executable — pure ELF
inspection via elfutils):
```sh
# Inside the container or any Linux host with elfutils:
eu-unstrip -n --core core.dump | grep libcoreclr      # definitive build-ID
strings -a core.dump | grep "Microsoft.NETCore.App/"  # quick version banner
file core.dump                                        # arch / ELF note
```
(`lldb -c core.dump -o "image list"` is **not** reliable here — bare lldb
reports "no associated executable images" for createdump cores; it needs the
executable. Use `delve-lldb`, which supplies it.)

Non-Microsoft runtimes (Red Hat builds, etc.) have no DAC on the Microsoft
symbol server. Supply the matching `libmscordaccore.so` in `./symbols/` and use
`setclrpath /symbols-user` inside the session [[⁴]](#references).

---

## Reproducibility

The image uses the newest .NET SDK and tools intentionally — that's what makes
it resilient to version drift. Each built image records exact versions in
`provenance.txt` (surfaced at the top of `analysis.txt`). To reproduce an
earlier case exactly, re-pin every value via `--build-arg`:

```sh
docker compose build \
    --build-arg DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0@sha256:<digest> \
    --build-arg FILESERVER_VERSION=v2026.2.515
```

---

## Smoke test

```sh
# Full end-to-end: build with in-image smoke + start + HTTP check + exec check
./smoke.sh                 # defaults to sos
./smoke.sh trace           # or trace / gcdump
./smoke.sh all             # all three siblings, sequentially

# In-image only (faster — runs during docker build):
docker compose build --build-arg SMOKE_TEST=1
```

A weekly CI workflow (`.github/workflows/rot-check.yml`) builds and smoke-tests
all three siblings automatically with no version pins, catching toolchain rot
before an incident. A fast per-PR `ci.yml` runs the byte-exact parity gates
(no Docker) on every push.

For **manual** acceptance-testing of a release (browse the rendered report and
the welcome screen yourself), use the persistent demo instead — it generates
its own real artifact, builds, and leaves a container running on
`localhost:5550`:

```sh
./demo.sh                 # defaults to sos
./demo.sh trace           # or trace / gcdump
                          # open http://localhost:5550/analysis/analysis.md
                          # welcome: docker exec -it dotnet-autopsy-demo-sos bash
docker rm -f dotnet-autopsy-demo-sos && docker rmi dotnet-autopsy-demo-sos   # when done
```

`demo.sh` is idempotent (re-run it after each change); unlike `smoke.sh` (a
self-cleaning pass/fail test) it stays up for inspection.

---

## Parity gate (byte-exact regression contract)

The report tools (`analysis_md.cs`, `json-get.cs`, and each image's triage
app) are pure deterministic transformers: `input + argv → stdout`, no
clock, no network, no environment reads. That makes their correctness
**provable by byte-diff against a committed baseline**, not by judgement
— which is exactly what the parity gate does.

```sh
bash common/parity/run-parity.sh sos      # or trace / gcdump
```

PASS == every fixture's stdout is byte-identical to its committed
golden. Any drift fails the gate and is treated as a regression unless
deliberately re-baselined (see CONTRIBUTING.md).

### Directory contract

| Path | Role |
|---|---|
| `<image>/parity/fixtures/<case>/` | Inputs: `args` (CLI argv, one per line), `raw.txt` (the report-tool stdout the triage parses), `analysis.txt` / `status.json` (the assembled input the renderer/json-get consumes). |
| `<image>/parity/golden/<case>.{triage,md,jsonget}` | Expected outputs: the locked-in stdout of `triage_summary` / `analysis_md` / `json-get` for that fixture. Hand-edits forbidden — only `--seed-golden` after manual verification. |
| `common/parity/run-parity.sh` | The gate. Publishes each `.cs` / `.csproj` once, runs it on every fixture, `cmp`s stdout against the golden. Modes: `GOLDEN` (default), `ORACLE` (when a `.py` reference exists — historical), and `--seed-golden` (capture current output as the new baseline). |

`gcdump` and `trace` are GOLDEN-only — they never had a Python oracle.
Their goldens were captured from the first verified-correct run via
`--seed-golden` and are the regression baseline from then on.

### Three CI tiers, one mental model

| Workflow | Trigger | Cost | Catches |
|---|---|---|---|
| `ci.yml` (parity) | every PR / push to main | ~30 s, no Docker | Report-tool output regressions, byte-exact |
| `rot-check.yml` (smoke) | weekly + path triggers | full Docker build per image | Toolchain rot (`dotnet`, file server, apt deps), behavioral assertions on the rendered report |
| `publish.yml` | tag push `v*.*.*` | multi-arch build + sign | Release: GHCR push of `dotnet-autopsy-base` with cosign + SBOM + SLSA provenance |

The parity gate is the fast inner loop; smoke is the broad outer
loop; publish is release-time. Phase A's whole rationale was "make the
parity gate green proves the restructure changed no semantics" — that
discipline holds for every subsequent phase. See `CONTRIBUTING.md` for
the developer workflow and `common/parity/run-parity.sh` header for the
full mechanics.

---

## Security

- **Sensitive artifact.** Core dumps contain process memory (connection strings,
  tokens, PII). Do not push analysis images to a shared registry.
- **localhost only.** `docker compose up` binds to `127.0.0.1:5550` — not
  reachable from other hosts on the network.
- **Do not use `--network host`** — this exposes the unauthenticated file server
  to all network interfaces.
- **Lifecycle.** Each case is a disposable image. After analysis:
  ```sh
  docker compose down
  docker rmi dotnet-autopsy-sos   # or dotnet-autopsy-trace / dotnet-autopsy-gcdump
  docker image prune -f
  ```

---

## Adapting the base image

The canonical default is `mcr.microsoft.com/dotnet/sdk:10.0` — the path
the parity GOLDEN gate covers. But the base image is intentionally a
**swap point**: real teams ship images on whatever distro their security
/ procurement / compliance stack mandates (Chainguard / Wolfi, Red Hat
UBI, Ubuntu LTS variants, Azure Linux, Alpine, Amazon Linux, internal
hardened distros…), and dotnet-autopsy was designed to be portable
across them.

Two adaptation paths are supported:

| Path | Use when… |
|---|---|
| **[Chainguard / Wolfi](#chainguard--wolfi-supported-automated-adaptation)** *(automated; shipped in this repo)* | Your org standardizes on Chainguard. One command builds it — `./chainguard/build.sh`. |
| **[Manual adaptation checklist](#manual-adaptation-checklist-other-distros)** | Any other distro. Six small edits to `common/base.dockerfile` (or a sibling Dockerfile). |

**Common to both paths.** The package-install block in
`common/base.dockerfile` is the main thing that changes when swapping
base images. The DAC is downloaded by build-ID and is independent of
the base image version [[³]](#references). The .NET tools — including
PowerShell (`pwsh`), installed via `dotnet tool install` — are
base-image-independent too. The only other base-dependent spot is the
**login-shell PATH snippet**: `ENV PATH=/opt/bin:$PATH` is portable
(Docker injects it into every `docker exec`), but the `/etc/profile.d` +
`~/.bashrc` hardening that keeps `/opt/bin` on PATH for *login* shells
is Debian/bash/root-specific.

### Chainguard / Wolfi (supported automated adaptation)

If your organization standardizes on **Chainguard**'s supply chain
(Wolfi base images, signed APKs, distroless production runtimes),
dotnet-autopsy ships a ready-to-build implementation of the
adaptation flow. The generated dockerfile is **committed** to the repo
(`chainguard/base.dockerfile`), so a fresh clone can build immediately
— no generator step required:

```sh
# Bash / WSL
./chainguard/build.sh              # build the Chainguard base
./chainguard/build.sh sos          # base + sos per-case image

# Windows / PowerShell
.\chainguard\build.ps1
.\chainguard\build.ps1 sos
```

(`chainguard/generate.sh` is a *maintenance* tool — maintainers run it
when `common/base.dockerfile` changes upstream, regenerate
`chainguard/base.dockerfile`, and commit. See
[`chainguard/README.md` § Two flows](chainguard/README.md#two-flows-user-vs-maintainer).)

The wrappers tag the result as `dotnet-autopsy-base` — the same tag the
canonical pipeline produces — so all three per-image flows (`sos`,
`trace`, `gcdump`) work on top of it unchanged. **Full instructions,
caveats (lldb on the free Chainguard feed, the `DOTNET_ROLL_FORWARD`
shim for `dotnet-monitor`), and the regeneration workflow live in
[`chainguard/README.md`](chainguard/README.md).**

Mechanically, the Chainguard adaptation is just the manual checklist
below applied automatically: `chainguard/generate.sh` reads
`common/base.dockerfile` and emits a Wolfi-flavored variant with
`apt-get` → `apk add`, `USER root` after `FROM`, and a few env shims.
Use it as a worked example if you're adapting to a different distro.

The Chainguard variant is intentionally **additive**: the canonical
Microsoft-SDK base remains the supported, parity-gated default, and a
CI guard (`.github/workflows/chainguard-isolation.yml`) prevents
chainguard changes from bleeding into the canonical pipeline.

### Manual adaptation checklist (other distros)

For any distro without a shipped automation here — Ubuntu
`-jammy`/`-noble`, Azure Linux, Alpine, Red Hat UBI, Amazon Linux,
internal hardened bases — apply this checklist directly to
`common/base.dockerfile` (or a sibling Dockerfile). The Chainguard
generator implements exactly these steps; you can crib from
`chainguard/generate.sh` as a worked example.

1. Change `DOTNET_SDK_IMAGE` to the distro's .NET SDK image.
2. Replace the `apt-get` block with the distro's package manager
   (`apk add`, `dnf install`, `microdnf install`, …) — package names
   are usually the same.
3. Use a development variant — distroless images have no shell, which
   breaks interactive delving.
4. Add `USER root` before build steps if the base runs as `nonroot`.
5. Pin by image digest for reproducibility.
6. **PATH for login shells.** `ENV PATH=/opt/bin:$PATH` already makes `pwsh`
   and the `dotnet-*` tools resolve for the documented
   `docker exec -it … bash` (non-login) on any base. The extra hardening for
   *login* shells (`bash -l`, `sh -lc`) is Debian-specific and needs review on
   minimal/non-Debian distros:
   - `/etc/profile.d/dotnet-autopsy.sh` only helps if the base's `/etc/profile`
     exists and sources `/etc/profile.d/*.sh` — verify this on the chosen
     image (minimal images may omit it, or use busybox `sh` whose
     login behavior differs).
   - `/root/.bashrc` only applies to a root + bash runtime. If you keep the
     image `nonroot`, write that PATH/MOTD snippet to the runtime user's home
     (e.g. `/home/nonroot/.bashrc`) or to `/etc/bash.bashrc` instead.
   - Keep the `ENV PATH=/opt/bin:$PATH` line regardless — it is the portable
     part and is what the smoke/rot-check assertions rely on.

If your distro becomes a recurring target, consider contributing a
sibling automation alongside `chainguard/` — model on
`chainguard/generate.sh` (input: canonical dockerfile; output: distro-
flavored variant).

---

## Published base image (`ghcr.io/janusmael/dotnet-autopsy-base`)

The shared toolchain — `dotnet-autopsy-base` — is published to GitHub
Container Registry on every release tag (multi-arch amd64/arm64, signed
with `cosign` keyless OIDC, with a CycloneDX SBOM and SLSA build
provenance attached). Per-case images (`sos`, `trace`, `gcdump`) are
**NOT** published — they bake user-supplied dump/trace/gcdump captures
(process memory + PII) and the family's air-gapped default depends on
them staying local-only.

Consume the published base in your own per-case Dockerfile:

```dockerfile
# Pin by tag for reproducibility…
FROM ghcr.io/janusmael/dotnet-autopsy-base:v1.0.0

# …or by digest for cryptographic certainty (recommended for prod):
# FROM ghcr.io/janusmael/dotnet-autopsy-base@sha256:<DIGEST>

COPY my.dump /analysis/my.dump
RUN /opt/analyze.sh   # or analyze-trace.sh / analyze-gcdump.sh
```

Verify the signature and SBOM before consuming:

```sh
docker pull ghcr.io/janusmael/dotnet-autopsy-base:v1.0.0

# Verify keyless-OIDC signature
cosign verify ghcr.io/janusmael/dotnet-autopsy-base:v1.0.0 \
  --certificate-identity-regexp 'https://github.com/.+/dotnet-.+/\.github/workflows/publish\.yml@refs/tags/v.+' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'

# Extract the SBOM attestation
cosign download attestation ghcr.io/janusmael/dotnet-autopsy-base:v1.0.0 \
  --predicate-type=https://cyclonedx.org/bom \
  | jq -r .payload | base64 -d | jq .predicate > base.cyclonedx.json
```

Publishing is driven by `.github/workflows/publish.yml`:

- **Auto** on `git push origin v1.x.y` — fully signed + attested.
- **Manual** via `gh workflow run publish.yml` — defaults to `dry_run=true`
  (builds without pushing). Set `dry_run=false` to publish a one-off tag.

Maintainers: see **`CONTRIBUTING.md` § *Cutting a release*** for the
end-to-end checklist (versioning, CHANGELOG promotion, tag, dry-run,
verify, rollback).

Per-case images (`dotnet-autopsy/sos`, etc.) remain a `docker build`-on-
demand model. If you have a hosted use case for a *dump-less* per-case
image variant (e.g. a public hands-on tutorial), open an issue — the
publish workflow has the building blocks (multi-arch + cosign + SBOM) and
adding an opt-in per-case job is a small follow-up.

---

> If you find this tool useful, I accept tips / donations:
>
> ❤️ ~B [![Sponsor](https://img.shields.io/static/v1?label=Sponsor&message=%E2%9D%A4&logo=GitHub&color=%23fe8e86)](https://github.com/sponsors/JanusMael)

## References

1. [SOS debugging extension — DAC must match runtime & arch](https://github.com/dotnet/diagnostics/blob/main/documentation/FAQ.md)
2. [Docker multi-platform builds & Apple Silicon Rosetta](https://docs.docker.com/build/building/multi-platform/)
3. [dotnet-symbol — downloads DAC/DBI/symbols matched by build-ID](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-symbol)
4. [dotnet-dump — version matching, setclrpath](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-dump)
5. [Debug Linux dumps](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/debug-linux-dumps)
6. [.NET dumps FAQ / createdump](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/faq-dumps)
7. [File server releases (per-RID assets)](https://github.com/JanusMael/Bennewitz.Ninja.FileServer/releases)
