# Changelog

All notable changes to dotnet-autopsy are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions are the git tags that trigger the `publish.yml` workflow, in the
repo's calendar scheme `v<YYYY>.<series>.<M><DD>` (see `CONTRIBUTING.md`
§ *Versioning*). Every tag publishes exactly one `dotnet-autopsy-base`;
per-case images are never published.

---

## [Unreleased]

---

## [v2026.2.902] — 2026-09-02

### Changed

- **File server is now the `Bennewitz.Ninja.FileServer` NuGet library**
  (2026.9.2), hosted by a small ASP.NET Core app at `common/FileServerHost/`,
  replacing the prebuilt per-RID single-file binary downloaded from GitHub
  releases. One framework-dependent publish runs on amd64 and arm64 alike,
  so the `DUMP_ARCH` RID switch and the curl → tar → find → chmod dance are
  gone. The host keeps the old CLI contract (`--root` / `--route` /
  `--http-port`) and adds the `/` → `/analysis` redirect explicitly, so every
  documented URL — including `?raw=1` — is unchanged.
  `FILESERVER_VERSION` now names a NuGet package version: `latest` floats to
  the newest stable (rot-check's "no pins" philosophy), anything else pins.
  `RELEASE.txt` records the version that actually resolved, so `dsos-info`
  is accurate in both modes. Startup is warning-free (in-memory
  DataProtection key ring; the base image's baked `ASPNETCORE_HTTP_PORTS`
  no longer conflicts with `--http-port`). This is the base's one NuGet
  package dependency; report apps stay BCL-only. (#5)
- **rot-check: the sos arm64 job is build-only.** GitHub's `ubuntu-latest`
  runners emulate arm64 via QEMU user-mode, which cannot run `createdump`,
  and the baked dump is generated x64 on the native runner. arm64 now
  verifies the image *builds* cross-platform (SMOKE_TEST off) and the
  runtime/analysis steps are gated to amd64 — the job goes legitimately
  green instead of a tolerated red X. trace/gcdump arm64 were unaffected
  (no createdump). (#2)
- **chainguard: the generator inherits `DOTNET_ROLL_FORWARD` from the
  canonical base** instead of inserting its own copy, so a regeneration can
  no longer produce a duplicated `ENV`. (#4)

### Fixed

- **Base image toolchain smoke failed with exit 150** once the floated
  `mcr.microsoft.com/dotnet/sdk:10.0` image stopped shipping the .NET 9
  runtime side-by-side: the pinned `dotnet-monitor 9.0.0` could no longer
  find its framework. `ENV DOTNET_ROLL_FORWARD=Major` lets the pinned tool
  run on the newer runtime that is present — the rot-resilience this image
  is built for. Report apps target the current major and exact-match first,
  so parity output is unaffected. (#1)
- **Publish workflow pre-warms Microsoft Container Registry** with backoff
  before the buildx step, absorbing the transient `403`/`429` on the
  `dotnet/sdk:10.0` manifest lookup that GitHub-hosted runners occasionally
  hit (it failed the `v2026.2.522` arm64 publish). (#3)

---

## [v2026.2.528] — 2026-05-28

### Added

- **Chainguard / Wolfi adaptation** (`chainguard/`): a generator
  (`generate.sh` / `generate.ps1`) that transforms `common/base.dockerfile`
  into a Wolfi-flavored variant (Chainguard SDK image, `apt` → `apk`, `USER
  root`), build wrappers that tag the result as `dotnet-autopsy-base` so all
  three per-image flows work on it unchanged, and a user-facing README.
  `chainguard/base.dockerfile` is generated but committed so a fresh clone
  builds without running the generator. A `chainguard-isolation` CI guard
  blocks PRs that touch both `chainguard/` and canonical paths.

---

## [v2026.2.522] — 2026-05-22

Initial public release of the `dotnet-autopsy` family.

### Added

**Shared base (`dotnet-autopsy-base`)**
- Full .NET 10 SDK with all `dotnet-*` diagnostic tools (`dotnet-dump`,
  `dotnet-gcdump`, `dotnet-trace`, `dotnet-sos`, `dotnet-symbol`,
  `dotnet-counters`, `dotnet-stack`, `dotnet-monitor 9.0.0`)
- PowerShell 7 (`pwsh`), `lldb`, `gdb`, `elfutils`, `btop`, `fresh` editor
- Shared report apps (BCL-only, no NuGet): `analysis_md`, `json-get`
- `analyze-common.sh` library (banner, provenance, assembly, status, render)
- `smoke-common.sh` library (build/run/wait/assert/teardown skeleton)
- Shared parity gate: `common/parity/run-parity.sh`
- Multi-arch publish to GHCR (`publish.yml`): cosign keyless signature,
  CycloneDX SBOM, SLSA provenance, amd64 + arm64
- Weekly rot-check CI (`rot-check.yml`) for all three images

**`dotnet-autopsy/sos` — Linux .NET core dump analysis**
- Automated SOS/dotnet-dump analysis at build time
- DAC fetched by build-ID from Microsoft symbol server
- Triage: exception chain, faulting thread, managed call stacks, top heap types,
  heuristic warnings
- Inner-exception expansion (configurable depth, default 9)
- Interactive: `delve` (dotnet-dump wrapper), `delve-lldb` (lldb + SOS)
- Byte-exact parity gate with 6 fixtures (success, lowfi, minimal, triage_heur,
  triage_unexp, xssfail)

**`dotnet-autopsy/trace` — `dotnet-trace` capture analysis**
- `dotnet-trace report` (top CPU) + `convert --format speedscope` (flame graph)
- TraceEvent depth: GC summary (GCStart/GCStop pairs), exception histogram
  (ExceptionStart events), runtime version probe (RuntimeStart)
- Speedscope JSON served at `/analysis/trace.speedscope.json`
- Byte-exact parity gate with 3 fixtures (success, degraded, failed)

**`dotnet-autopsy/gcdump` — `dotnet-gcdump` heap snapshot analysis**
- `dotnet-gcdump report` parsed into TOP TYPES BY SIZE with heap summary
  and dominator heuristics
- Byte-exact parity gate with 1 fixture (success)

**Shared UX**
- Navigable `analysis.md` rendered by Markdig (headings, TOC, fenced bodies)
- XSS controls: all dump-derived content in dynamically-fenced blocks
- `analysis.txt` remains the authoritative raw source tooling asserts on
- `status.json` for machine-readable health (`json-get` utility)
- `/analysis/sources/` — reusable standalone .NET 10 report apps
- `docker compose up` default (no `--profile` needed for `sos`)
- `demo.sh sos|trace|gcdump` — persistent interactive instance
- `smoke.sh sos|trace|gcdump|all` — self-cleaning pass/fail CI test

[Unreleased]: https://github.com/JanusMael/dotnet-autopsy/compare/v2026.2.902...HEAD
[v2026.2.902]: https://github.com/JanusMael/dotnet-autopsy/compare/v2026.2.528...v2026.2.902
[v2026.2.528]: https://github.com/JanusMael/dotnet-autopsy/compare/v2026.2.522...v2026.2.528
[v2026.2.522]: https://github.com/JanusMael/dotnet-autopsy/tree/v2026.2.522
