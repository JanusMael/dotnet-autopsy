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

## Chainguard adaptation — kept isolated

The `chainguard/` directory (Wolfi/musl variant) is **intentionally additive**:
it is a transformation of `common/base.dockerfile`, not a replacement, and
the parity GOLDEN gate covers only the canonical Microsoft-SDK base. To keep
the two paths honest, a CI check (`.github/workflows/chainguard-isolation.yml`)
fails any PR that modifies `chainguard/` **and** touches the canonical
pipeline paths:

- `common/**`, `sos/**`, `trace/**`, `gcdump/**`
- `build.sh`, `build.ps1`, `demo.sh`, `smoke.sh`, `docker-compose.yml`

If a change genuinely spans both, land them as two PRs: the canonical-side
change first (parity gate re-verifies), then the chainguard regen on top.
Top-level docs (`README.md`, `CHANGELOG.md`, etc.) and the `.github/` directory
remain freely co-editable with `chainguard/`.

## Commit style

- Prefer new commits over amend.
- One logical change per commit; include the image name in the subject when relevant
  (`sos:`, `trace:`, `gcdump:`, `common:`).
- Never skip hooks (`--no-verify`).

## Cutting a release (maintainers)

Releases are **fully tag-driven**: pushing an annotated `vX.Y.Z` tag to
the repo triggers `.github/workflows/publish.yml`, which builds the
`dotnet-autopsy-base` image for amd64 + arm64, signs it with cosign
keyless OIDC, attaches a CycloneDX SBOM, attests SLSA build provenance,
and pushes the multi-arch manifest to GHCR (`ghcr.io/janusmael/dotnet-autopsy-base`).
Moving `:latest` happens automatically on tag pushes (not on
`workflow_dispatch`).

Per-case images (`sos`, `trace`, `gcdump`) are intentionally **not**
published — they bake user-supplied artifacts (process memory + PII).
Only the base ships.

### Versioning

Semantic versioning. The base is the unit of versioning:

- **Major** (`v2.0.0`) — breaking change to the consumed shape of the
  base: shell PATH layout, `/opt/report-bin/*` binary paths, MOTD
  format, `/analysis/sources/` README contract — anything a downstream
  `FROM ghcr.io/.../dotnet-autopsy-base` consumer could rely on.
- **Minor** (`v1.1.0`) — new feature in any of the three images
  (e.g. a new triage section, a new sibling) without breaking the base
  consumption shape.
- **Patch** (`v1.0.1`) — bug fix, doc update, dependency bump, hotfix.

### Release checklist

```sh
# 1.  Make sure main is up to date and parity is green
git checkout main && git pull
bash common/parity/run-parity.sh sos
bash common/parity/run-parity.sh trace
bash common/parity/run-parity.sh gcdump

# 2.  (Optional but encouraged) full smoke
./smoke.sh all

# 3.  Promote the CHANGELOG: move [Unreleased] entries under a new
#     [vX.Y.Z] — YYYY-MM-DD heading; leave [Unreleased] empty for the
#     next cycle. Bump the link references at the bottom.

# 4.  Commit the CHANGELOG bump
git add CHANGELOG.md
git commit -m "release: vX.Y.Z"

# 5.  Tag (annotated; use the CHANGELOG entry as the tag message body)
git tag -a vX.Y.Z -m "vX.Y.Z

<paste the CHANGELOG section body here>"

# 6.  Push the commit AND the tag
git push origin main
git push origin vX.Y.Z

# 7.  The publish.yml workflow auto-fires on the tag push. Watch:
gh run watch              # or open the Actions tab
#     ~10–15 min: per-arch builds → manifest → cosign + SBOM + SLSA

# 8.  Verify the published artifact
docker pull ghcr.io/janusmael/dotnet-autopsy-base:vX.Y.Z
cosign verify ghcr.io/janusmael/dotnet-autopsy-base:vX.Y.Z \
  --certificate-identity-regexp 'https://github.com/.+/dotnet-.+/\.github/workflows/publish\.yml@refs/tags/v.+' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'

# 9.  (Optional) Create a GitHub Release at the tag with the CHANGELOG
#     entry as the body — surfaces release notes on the Releases page.
gh release create vX.Y.Z --title "vX.Y.Z" \
  --notes "$(awk '/^## \[vX.Y.Z\]/,/^## \[/' CHANGELOG.md | sed '$d')"
```

### Dry-run (no push to GHCR)

To validate publish.yml end-to-end without publishing — e.g. the first
release on a fresh `IMAGE_NAME`, or after a workflow change:

```sh
gh workflow run publish.yml -f dry_run=true -f tag=v0.0.0-test
# Builds both arches, runs through all jobs except the manifest+sign
# job. Nothing is pushed to GHCR; `:latest` is not moved.
```

### Rollback

There's no automated rollback. To recover from a bad release:

1. **Move `:latest` back to the previous good tag manually:**
   ```sh
   docker buildx imagetools create -t ghcr.io/janusmael/dotnet-autopsy-base:latest \
     ghcr.io/janusmael/dotnet-autopsy-base:vX.Y.Z-prev
   ```
2. **Do not delete the bad tag** — published cosign signatures and SBOM
   attestations reference its digest. Cut a new patch release
   (`vX.Y.Z+1`) with the fix instead.
3. If the bad tag exposes a security vulnerability, follow `SECURITY.md`
   for the disclosure path before publishing the fix.

### What `publish.yml` does (high level)

| Job | What |
|---|---|
| `derive` | Resolves the tag + `dry_run` + whether to move `:latest`. |
| `build-per-arch` (matrix amd64 / arm64) | Builds `common/base.dockerfile` per-arch; pushes `:vX.Y.Z-{arch}`. GHA cache scoped per-arch. |
| `manifest` (only if not dry-run) | Creates multi-arch manifest `:vX.Y.Z`; moves `:latest`; cosign-signs the digest; generates + attests CycloneDX SBOM; attaches SLSA provenance. |
| `dry-run-summary` (only if dry-run) | Reports that nothing was pushed. |

The job summary on a successful run prints the pull + verify snippets
inline — copy-paste-ready.

## License

By contributing you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
