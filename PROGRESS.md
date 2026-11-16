# Work state — dotnet-autopsy

Current state and open threads. History lives in `CHANGELOG.md`; conventions
and invariants in `CONTRIBUTING.md`. This file is replaced, not appended.

## Status: released and verified

| Fact | Value |
|---|---|
| Tag | `v2026.2.902` (CalVer — `CONTRIBUTING.md` § Versioning) |
| Image | `ghcr.io/janusmael/dotnet-autopsy-base` |
| Manifest digest | `sha256:666b3be93a3c2a8f557239ed5fc438997e99b92a038af0f282691f427afbcaaa` |
| Platforms | `linux/amd64`, `linux/arm64` |
| `:latest` | same digest |
| Provenance | SLSA attested — `gh attestation verify oci://… --owner JanusMael` passes |

The released image was confirmed to contain the NuGet-backed file server
(`Bennewitz.Ninja.FileServer 2026.9.2`) from the publish logs of both arch
builds. Per-case images (`sos`, `trace`, `gcdump`) are never published: they
bake user artifacts containing process memory and PII.

PRs #1–#7 are all merged. Nothing is in flight.

## Open

| Item | Detail |
|---|---|
| GitHub Release page | None exists for any tag; tags publish straight to GHCR, so this is cosmetic. Recipe: `CONTRIBUTING.md` § Cutting a release, step 9. |
| `.gitattributes` has no `*.csproj` rule | Git warns LF→CRLF on `common/FileServerHost/FileServerHost.csproj` and `trace/TraceTriage/TraceTriage.csproj`. Harmless to MSBuild in Linux Docker; a one-line `*.csproj text eol=lf` would normalize both. |

## Repository settings

`main` requires 1 approving review and declares no required status checks. A
solo maintainer cannot satisfy that on their own PR, so #1–#7 merged by admin
bypass with CI green. To make "merge when green" enforceable by GitHub
instead: add `Parity gate (sos)`, `Parity gate (trace)`,
`Parity gate (gcdump)` and the chainguard-isolation check as required, and
drop the review count to 0.

## Invariants

Enforced; authoritative text in `CONTRIBUTING.md` § Core invariants.

- Byte-exact parity GOLDEN gate stays green for `sos`, `trace`, `gcdump`.
- Report apps are BCL-only. Two deliberate NuGet exceptions:
  `trace/TraceTriage` (TraceEvent, parity-gated) and `common/FileServerHost`
  (infrastructure, outside the parity contract).
- Host binding is `127.0.0.1:5550`, never `0.0.0.0`.
- No diagnostic artifacts (dumps, traces, gcdumps) committed.
- A `chainguard/` change never shares a PR with canonical paths —
  `.github/workflows/chainguard-isolation.yml` enforces this. Land the
  canonical change first, then the chainguard regen.

## Known environment limits

- **arm64 rot-check for `sos` is build-only.** GitHub runners emulate arm64
  via QEMU, which cannot run `createdump`; the baked dump is x64 from the
  native runner. The job verifies the image builds and the runtime steps are
  gated to amd64.
- **`lldb` is absent from the free Chainguard and Wolfi feeds** (verified
  empirically). The Chainguard variant therefore has no `delve-lldb`; `delve`
  (dotnet-dump) is unaffected. Detail in `chainguard/README.md` § Caveats.
- **`dotnet-monitor` is pinned** and relies on `DOTNET_ROLL_FORWARD=Major` in
  `common/base.dockerfile` to launch once the base SDK image advances past
  its major.
- **Git Bash rewrites `rev:path` arguments.** `git show origin/main:.github/x.yml`
  becomes a Windows path and silently fails, so a file looks absent from a
  branch. Run such commands with `MSYS_NO_PATHCONV=1`, or under WSL.

## Next

1. Decide whether `v2026.2.902` gets a Release page.
2. Optionally retune `main`'s protection as above.

Branches: only `main` remains on the remote. Locally, `backup-pre-reset` is a
deliberate safety branch — keep it.
