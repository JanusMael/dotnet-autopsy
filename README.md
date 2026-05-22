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

> **Security note:** every captured artifact contains process memory or
> stack samples — secrets, tokens, PII, internal call sites. Treat every
> image produced by this tool as a sensitive artifact. See
> [Security](#security) for controls.

Below is the **`dotnet-autopsy/sos`** quick start; for the per-sibling
flows see **`trace/RUNBOOK.md`** (capturing a `.nettrace`, reading the
report, dotnet-trace cheat-sheet) and **`gcdump/RUNBOOK.md`** (capturing
a `.gcdump`, reading the heap report).

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

## Build arguments

| Arg | Default | Purpose |
|---|---|---|
| `DUMP_FILE` | `core.dump` | Dump filename in the repo root |
| `DUMP_ARCH` | `amd64` | Dump CPU architecture: `amd64` or `arm64`. **Must match the dump, not your laptop.** |
| `INNER_EXCEPTION_DEPTH` | `9` | Max wrapped-inner-exception expansion passes (FailFast / `AggregateException` unwrap). Raise for deeply-nested chains; `0` disables. Each pass reloads the dump. |
| `DOTNET_SDK_IMAGE` | `mcr.microsoft.com/dotnet/sdk:10.0` | Base image. Override to match the dump's OS (e.g. `…sdk:10.0-jammy`) |
| `FILESERVER_VERSION` | `latest` | File server release tag — pin for reproducibility (e.g. `v2026.2.515`) |
| `DOTNET_MONITOR_VERSION` | `9.0.0` | dotnet-monitor tool version — **pinned** (its release cadence is independent of the SDK; unpinned installs are unreliable) |
| `FRESH_VERSION` | `v0.3.6` | Fresh terminal-editor release tag — **pinned**, static musl binary fetched + sha256-verified at build |
| `SMOKE_TEST` | `0` | Set to `1` to run an end-to-end toolchain smoke test at build |

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

The package-install block in `sos/dotnet-sos.dockerfile` is the main change needed
to swap base images. The DAC is downloaded by build-ID and is independent of the
base image version [[³]](#references). The .NET tools — including PowerShell
(`pwsh`), installed via `dotnet tool install` — are base-image-independent too.
The only other base-dependent spot is the **login-shell PATH snippet** (see
point 6 below): `ENV PATH=/opt/bin:$PATH` is portable (Docker injects it into
every `docker exec`), but the `/etc/profile.d` + `~/.bashrc` hardening that
keeps `/opt/bin` on PATH for *login* shells is Debian/bash/root-specific.

**Chainguard / Wolfi:**
1. Change `DOTNET_SDK_IMAGE` to a Chainguard .NET SDK image.
2. Replace the `apt-get` block with `apk add --no-cache lldb gdb ...`
   (package names are the same on Wolfi).
3. Use the `-dev` variant — distroless images have no shell, which breaks
   interactive delving.
4. Add `USER root` before build steps if the base runs as `nonroot`.
5. Pin by image digest for reproducibility.
6. **PATH for login shells.** `ENV PATH=/opt/bin:$PATH` already makes `pwsh`
   and the `dotnet-*` tools resolve for the documented
   `docker exec -it … bash` (non-login) on any base. The extra hardening for
   *login* shells (`bash -l`, `sh -lc`) is Debian-specific and needs review on
   Wolfi:
   - `/etc/profile.d/dotnet-autopsy.sh` only helps if the base's `/etc/profile`
     exists and sources `/etc/profile.d/*.sh` — verify this on the chosen
     `-dev` image (minimal images may omit it, or use busybox `sh` whose
     login behavior differs).
   - `/root/.bashrc` only applies to a root + bash runtime. If you keep the
     image `nonroot`, write that PATH/MOTD snippet to the runtime user's home
     (e.g. `/home/nonroot/.bashrc`) or to `/etc/bash.bashrc` instead.
   - Keep the `ENV PATH=/opt/bin:$PATH` line regardless — it is the portable
     part and is what the smoke/rot-check assertions rely on.

Same swap for Ubuntu `-jammy`/`-noble` or Azure Linux: only the apt block and
base tag change.

---

## Published base image (`ghcr.io/JanusMael/dotnet-autopsy-base`)

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
FROM ghcr.io/JanusMael/dotnet-autopsy-base:v1.0.0

# …or by digest for cryptographic certainty (recommended for prod):
# FROM ghcr.io/JanusMael/dotnet-autopsy-base@sha256:<DIGEST>

COPY my.dump /analysis/my.dump
RUN /opt/analyze.sh   # or analyze-trace.sh / analyze-gcdump.sh
```

Verify the signature and SBOM before consuming:

```sh
docker pull ghcr.io/JanusMael/dotnet-autopsy-base:v1.0.0

# Verify keyless-OIDC signature
cosign verify ghcr.io/JanusMael/dotnet-autopsy-base:v1.0.0 \
  --certificate-identity-regexp 'https://github.com/.+/dotnet-.+/\.github/workflows/publish\.yml@refs/tags/v.+' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'

# Extract the SBOM attestation
cosign download attestation ghcr.io/JanusMael/dotnet-autopsy-base:v1.0.0 \
  --predicate-type=https://cyclonedx.org/bom \
  | jq -r .payload | base64 -d | jq .predicate > base.cyclonedx.json
```

Publishing is driven by `.github/workflows/publish.yml`:

- **Auto** on `git push origin v1.x.y` — fully signed + attested.
- **Manual** via `gh workflow run publish.yml` — defaults to `dry_run=true`
  (builds without pushing). Set `dry_run=false` to publish a one-off tag.

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
