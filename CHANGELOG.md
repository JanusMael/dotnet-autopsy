# Changelog

All notable changes to dotnet-autopsy are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions correspond to git tags pushed to trigger the `publish.yml` workflow.

---

## [Unreleased]

---

## [v1.0.0] — 2026-05-22

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

[Unreleased]: https://github.com/JanusMael/dotnet-autopsy/compare/v1.0.0...HEAD
[v1.0.0]: https://github.com/JanusMael/dotnet-autopsy/releases/tag/v1.0.0
