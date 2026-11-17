# AGENTS.md — `common/`

Everything the three per-case images share: the base image, the shared report apps, the shell
libraries, the file-server host and the parity gate.

| Path | What it is |
|---|---|
| `base.dockerfile` | Builds `dotnet-autopsy-base`, the only published image. Its `ARG`s are the build args in `README.md` § Build arguments |
| `analysis_md.cs`, `json-get.cs` | BCL-only file-based report apps: `analysis.txt` → `analysis.md`, and a reader for `status.json`. Baked into `/opt` and, as reusable sources, `/analysis/sources/` |
| `entrypoint.sh` | Container start: prints the status banner, then `exec`s the file server so signals reach it |
| `lib/analyze-common.sh` | Sourced by each image's analyze script, at `/opt/lib/analyze-common.sh`: assembly, status, render and banner helpers |
| `lib/smoke-common.sh` | Sourced by each image's `smoke.sh` on the host: build, run, HTTP, `pwsh` and status checks, cleanup. Never baked into an image |
| `FileServerHost/` | The ASP.NET Core host around the `Bennewitz.Ninja.FileServer` package that serves `/analysis` on port 5550. Infrastructure, outside the parity contract |
| `parity/run-parity.sh` | The parity gate. Publishes each report app into the gitignored `parity/_bin/` at the repository root and `cmp`s its output on every fixture against the golden |

## Rules

| Rule | Why | Guarded by |
|---|---|---|
| The report apps are pure: input and argv to stdout, no clock, no network, no environment reads | That is what makes byte-for-byte comparison a valid test | `parity/run-parity.sh`; `ci.yml` |
| `analysis_md.cs` and `json-get.cs` serve all three images, so a change runs the gate for `sos`, `trace` and `gcdump` | One image's goldens can drift while another's stay green | `ci.yml` runs all three on every PR |
| `lib/analyze-common.sh` and `lib/smoke-common.sh` only define functions | They are sourced; top-level code would run inside every caller | the header of each file |
| `lib/analyze-common.sh` expects its caller to have set the variables its header lists | A helper reads an empty path and writes the report somewhere else | the header; the parity gate |
| `sc_status_check` in `lib/smoke-common.sh` fails only on `status=failed`; sos adds its own stricter `sos_status_assert` | Loosening the shared check weakens every image's smoke | `sos/smoke.sh` |
| `base.dockerfile` keeps `DOTNET_ROLL_FORWARD=Major` | Pinned tools can target an older major than the SDK image: PowerShell 7.6.10 targets .NET 10 and launches on 11 only through it | the comments beside it and beside `POWERSHELL_VERSION` |
| `POWERSHELL_VERSION` stays pinned until a 7.7.x installs | PowerShell 7.7.0's `powershell.linux-x64` dependency is missing from nuget.org, so the unpinned tool fails every build | `PROGRESS.md`, Known environment limits |
| A change to `base.dockerfile` is followed by a Chainguard regeneration in its own PR | `chainguard/base.dockerfile` is generated from this file and goes stale silently | `.github/workflows/chainguard-isolation.yml` keeps the two PRs apart |
| `FileServerHost` listens on `0.0.0.0` inside the container, so the host-side publish is the only boundary, and it is `127.0.0.1` | The server is unauthenticated and serves process memory | the comment in `FileServerHost/Program.cs`; `docker-compose.yml`; `lib/smoke-common.sh` |

The gate needs the .NET 11 SDK on the host and no Docker. `--seed-golden` rewrites the goldens from
the current output; use it only after checking that output by hand.
