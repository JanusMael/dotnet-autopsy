# Contributing to dotnet-autopsy

Thank you for your interest in contributing.

## Before you start

- For **bug reports** or **feature requests**, open an issue using the appropriate template.
- For **significant changes** (new image sibling, new triage section, new tool), open an issue first to discuss the approach before writing code. This project has strict invariants (see below) that affect design choices.

## Core invariants

These are non-negotiable and must be preserved by any contribution:

1. **Byte-exact parity gate.** `bash common/parity/run-parity.sh <image>` must stay
   `ALL FIXTURES BYTE-IDENTICAL` for all three images (`sos`, `trace`, `gcdump`).
   Run it before every commit that touches a report app or analyze script.

2. **No python3.** The image is zero-Python. Report logic lives in BCL-only .NET 10
   file-based apps (`*.cs`, no NuGet) — except `trace/TraceTriage/` which uses the
   `Microsoft.Diagnostics.Tracing.TraceEvent` NuGet package and is the deliberate
   exception.

3. **localhost-only binding.** Every `docker run` and `docker compose up` must bind
   to `127.0.0.1:5550`, never `0.0.0.0`. The images bake process memory (dumps,
   traces, heap snapshots) and must never be reachable from the network.

4. **No core dumps / traces / gcdumps committed.** Diagnostic artifacts contain
   process memory (PII, tokens). Only synthetic smoke fixtures generated inside
   throwaway SDK containers are permitted (and those are regenerated, never stored).

## Development workflow

```sh
# 1. Make changes
# 2. Run parity gates (fast, no Docker)
bash common/parity/run-parity.sh sos
bash common/parity/run-parity.sh trace
bash common/parity/run-parity.sh gcdump

# 3. Run the full demo for any image you touched (Docker required)
./demo.sh sos        # or trace / gcdump
# Open http://localhost:5550/analysis/analysis.md and verify visually

# 4. Optionally run the smoke test (self-cleaning pass/fail)
./smoke.sh sos       # or trace / gcdump / all
```

If you change a report app (`.cs`) or analyze script and the parity gate drifts,
**do not re-seed the golden** without a clear justification — drift means a regression
or an intentional change. Intentional changes should update both the code and the
golden in the same commit with an explanation in the commit message.

## Re-seeding goldens

Only re-seed after verifying the new output is correct:

```sh
bash common/parity/run-parity.sh <image> --seed-golden
```

Then commit the updated golden files alongside the code change.

## Adding a new image sibling

The three existing siblings (`sos`, `trace`, `gcdump`) establish the pattern:

- `<image>/dotnet-<image>.dockerfile` — thin `FROM dotnet-autopsy-base`
- `<image>/analyze-<image>.sh` — sources `common/lib/analyze-common.sh`
- `<image>/<triage_app>` — BCL-only `.cs` or `.csproj` (TraceEvent only)
- `<image>/smoke.sh` — thin caller of `common/lib/smoke-common.sh`
- `<image>/RUNBOOK.md`
- `<image>/parity/fixtures/` + `parity/golden/`

Wire into `build.sh`, `build.ps1`, `docker-compose.yml`, `demo.sh`, `smoke.sh`,
`rot-check.yml`, and `README.md`. Add a profile to `common/analysis_md.cs`.

## Commit style

- Prefer new commits over amend.
- One logical change per commit; include the image name in the subject when relevant
  (`sos:`, `trace:`, `gcdump:`, `common:`).
- Never skip hooks (`--no-verify`).

## License

By contributing you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
