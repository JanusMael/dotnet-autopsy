# AGENTS.md — `.github/`

The workflows and the repository's GitHub files.

| File | What it is |
|---|---|
| `workflows/ci.yml` | The parity gate for `sos`, `trace` and `gcdump` on the 11.0.x SDK, on every push to `main` and every PR to it. No Docker |
| `workflows/chainguard-isolation.yml` | Fails a PR that touches `chainguard/` together with a canonical pipeline path |
| `workflows/rot-check.yml` | Builds and smoke-tests all three images, amd64 and arm64, with nothing pinned beyond the base's pins: weekly, on dispatch, and on pushes and PRs touching the pipeline paths |
| `workflows/publish.yml` | Builds, signs (cosign keyless), attests (CycloneDX SBOM, SLSA provenance) and pushes `dotnet-autopsy-base` to GHCR on a `v*.*.*` tag; a dispatch defaults to a dry run |
| `CODEOWNERS`, `FUNDING.yml`, `ISSUE_TEMPLATE/`, `pull_request_template.md` | Ownership, sponsorship, and the issue and PR forms |
| `copilot-instructions.md` | A pointer to the root `AGENTS.md` for tools that look here |

## Rules

| Rule | Why |
|---|---|
| **A job's name is part of `main`'s branch protection.** `Parity gate (sos)`, `Parity gate (trace)`, `Parity gate (gcdump)` and `chainguard/ touches do not bleed into canonical paths` are required checks; renaming one means updating the protection in the same change | A required check that no job reports blocks every PR, and GitHub never says why |
| `ci.yml` and `chainguard-isolation.yml` run on every PR to `main`, with no path filter | A required check skipped by a filter never reports, and the PR stays blocked |
| `publish.yml` builds `common/base.dockerfile` and nothing else | Per-case images bake captured process memory and are never published |
| `publish.yml` moves `:latest` on a tag push only, never on a dispatch | A one-off dispatch would otherwise replace what consumers of `:latest` pull |
| The SDK version in `ci.yml` and in `rot-check.yml`'s parity job tracks the base image's .NET major | The gate otherwise builds the report apps for a runtime the images do not ship |
| `rot-check.yml`'s arm64 sos job is build-only | GitHub's arm64 runs are QEMU-emulated, where `createdump` cannot run; its runtime steps are gated to amd64 |

GitHub disables a scheduled workflow after 60 days without repository activity. When the weekly
rot-check goes quiet, `gh workflow list --all` shows it as `disabled_inactivity`.
