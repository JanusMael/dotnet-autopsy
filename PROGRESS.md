# Work state — dotnet-autopsy

Current state and open threads. History lives in `CHANGELOG.md`; conventions
and invariants in `CONTRIBUTING.md`. This file is replaced, not appended.

## Status: released and verified

| Fact | Value |
|---|---|
| Tag | `v2026.4.1117` (.NET 11; CalVer — `CONTRIBUTING.md` § Versioning) |
| Image | `ghcr.io/janusmael/dotnet-autopsy-base` |
| Manifest digest | `sha256:ca1e51280c639ab628e014dcf73cba561ce39b65cd48f5471a1e1747b3a234df` |
| Platforms | `linux/amd64`, `linux/arm64` |
| `:latest` | same digest |
| Signature | `cosign verify` with the README's identity regexp passes |
| Provenance | SLSA attested — `gh attestation verify oci://… --owner JanusMael` passes |
| Release page | GitHub Release `v2026.4.1117`, notes = the CHANGELOG section |

Tagged on `19348d4` (the #10 merge), published by `publish.yml` run
44147069031 on 2026-11-17. Per-case images (`sos`, `trace`, `gcdump`) are
never published: they bake user artifacts containing process memory and PII.

## Done: plan `plans/00001-dotnet-11.md`

All 13 steps are done: the .NET 11 upgrade (#8, 2026-11-16), the Chainguard
regeneration (#9) and the release (#10, the tag and the page, 2026-11-17).
#8–#10 merged by rebase, all checks green, no bypass.

Drift from the plan, decided by the developer on 2026-11-16 (details in the
`CHANGELOG.md` entry):

- PowerShell pinned to 7.6.10 (`ARG POWERSHELL_VERSION`); 7.7.0's
  `powershell.linux-x64` dependency is missing from nuget.org. Unpin once a
  7.7.x installs.
- `sc_status_check` fixed (root-caused neighbor): passing smokes exited 1,
  and Windows read every status as `unknown`.
- Chainguard sets `DOTNET_EnableEventLog=0` (generator rule 4): its image
  ships `liblttng-ust`, and with `1` `dotnet-sos` segfaults at exit.
- `chainguard/generate.ps1` and the Chainguard build wrappers fixed
  (root-caused neighbors).

## Decisions (developer, 2026-11-16)

| Decision | Choice |
|---|---|
| Merge method | Rebase merge, done by the developer (#8, #9). |
| `main` protection | Retuned to the family convention and applied; see Repository settings. |
| Conventions adopted | `.gitattributes` `* text=auto eol=lf` (done 2026-11-17; the index was already all LF, so the renormalization changed no content) and the AGENTS.md set (root and each top-level directory, a `CLAUDE.md` of `@AGENTS.md` beside each, `.github/copilot-instructions.md`). The AGENTS.md set landed 2026-11-17 as two PRs, because the chainguard-isolation guard keeps `chainguard/` apart from `common/` and the image directories: everything else first, then `chainguard/`. `symbols/AGENTS.md` and `CLAUDE.md` are excepted in `.gitignore` and excluded in `.dockerignore`, so they never reach the sos image's `/symbols-user/`. Not adopted: turning merge commits off, the `release-tags` ruleset, `.github/repository.json`, per-job `permissions` and major-tag pinning, the `conventions` job. Source: `C:\c\cl\Bennewitz.Ninja.Templates` `docs/repository-conventions.md`. |
| Release | Cut after #8 and #9, with a GitHub Release page whose notes are the CHANGELOG section. The tag is pushed only on the developer's word. |
| CalVer | `vYYYY.Q.MDD` from the UTC tag date, per `Bennewitz.Ninja.AutoVersioning` (checkout `C:\c\cl\Bennewitz.Ninja.AutoVersioning`). `v2026.2.902` should have been `v2026.3.902`; it stays, recorded in the CHANGELOG and `CONTRIBUTING.md`. |

## Repository settings

`main` (classic branch protection) requires a PR with 0 approvals, and four
status checks on an up-to-date branch: `Parity gate (sos)`,
`Parity gate (trace)`, `Parity gate (gcdump)` and
`chainguard/ touches do not bleed into canonical paths`. Conversations must
be resolved; force-pushes and deletion are blocked; admins can bypass. A PR
merges when green, without bypass. #1–#7 predate this and merged by admin
bypass.

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
- **Not yet exercised on Chainguard:** running `chainguard/build.ps1`, and
  the `trace` and `gcdump` images on the Chainguard base.
- **`dotnet-monitor` is pinned** and relies on `DOTNET_ROLL_FORWARD=Major` in
  `common/base.dockerfile` to launch once the base SDK image advances past
  its major.
- **Git Bash rewrites `rev:path` arguments.** `git show origin/main:.github/x.yml`
  becomes a Windows path and silently fails, so a file looks absent from a
  branch. Run such commands with `MSYS_NO_PATHCONV=1`, or under WSL. It
  also mangles `cosign verify`'s `--certificate-identity-regexp` typed
  inline, which then reports "no matching signatures" for a valid
  signature; run it from a script file.
- **Publish-run warnings, harmless today:** `ubuntu-latest` moves to
  Ubuntu 26, and the v3/v4/v6 `actions/*` and `docker/*` actions target
  Node.js 20, which GitHub runs on Node.js 24.
- **GitHub disables scheduled workflows after 60 days without repository
  activity.** Rot-check was disabled that way after its 2026-11-09 run and
  re-enabled 2026-11-16. If the weekly signal goes quiet, check
  `gh workflow list --all` for `disabled_inactivity`.
- **Earlier tag messages lack their `###` headings**: `git tag`'s default
  cleanup strips them as comments. The checklist now passes
  `--cleanup=whitespace`.

## Next

Nothing is queued. Plan 00001 and the adopted conventions are done.

Branches: locally, `backup-pre-reset` is a deliberate safety branch — keep
it. `feat/dotnet-11`, `chore/chainguard-regen-dotnet-11`,
`release/v2026.4.1117` and `docs/progress-v2026.4.1117` are merged
(rebased) and gone from the remote.
