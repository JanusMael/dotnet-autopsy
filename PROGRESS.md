# Work state — dotnet-autopsy

Current state and open threads. History lives in `CHANGELOG.md`; conventions
and invariants in `CONTRIBUTING.md`. This file is replaced, not appended.

## Status: releasing `v2026.4.1117` (.NET 11)

The last published release is still `v2026.2.902`:

| Fact | Value |
|---|---|
| Tag | `v2026.2.902` |
| Image | `ghcr.io/janusmael/dotnet-autopsy-base` |
| Manifest digest | `sha256:666b3be93a3c2a8f557239ed5fc438997e99b92a038af0f282691f427afbcaaa` |
| Platforms | `linux/amd64`, `linux/arm64` |
| Provenance | SLSA attested — `gh attestation verify oci://… --owner JanusMael` passes |

Per-case images (`sos`, `trace`, `gcdump`) are never published: they bake
user artifacts containing process memory and PII.

## In flight: the release (plan `plans/00001-dotnet-11.md`, step 13)

Steps 1–12 are done: the .NET 11 upgrade merged as #8 (2026-11-16) and the
Chainguard regeneration as #9 (2026-11-17), both by rebase with all checks
green and no bypass.

| Release step | State |
|---|---|
| Release PR on `release/v2026.4.1117`: CHANGELOG section, `CONTRIBUTING.md` § Versioning rewritten to the quarter rule, the checklist fitted to the protected `main`, README example tags | open |
| Tag `v2026.4.1117` on the merged `main` | after the PR merges, on the developer's word. If the merge lands on a later UTC day, the tag follows that date and the CHANGELOG heading is renamed |
| `publish.yml` run, `cosign verify`, attestation check | after the tag |
| GitHub Release page, notes = the CHANGELOG section | after the publish verifies |
| Record the new digest here | a small follow-up PR |

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
| Conventions adopted | `.gitattributes` `* text=auto eol=lf` (with a renormalization, which settles the `*.csproj` CRLF warnings) and the AGENTS.md set (root and each top-level directory, a `CLAUDE.md` of `@AGENTS.md` beside each, `.github/copilot-instructions.md`). Each lands as its own small PR after the release. Not adopted: turning merge commits off, the `release-tags` ruleset, `.github/repository.json`, per-job `permissions` and major-tag pinning, the `conventions` job. Source: `C:\c\cl\Bennewitz.Ninja.Templates` `docs/repository-conventions.md`. |
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
  branch. Run such commands with `MSYS_NO_PATHCONV=1`, or under WSL.
- **GitHub disables scheduled workflows after 60 days without repository
  activity.** Rot-check was disabled that way after its 2026-11-09 run and
  re-enabled 2026-11-16. If the weekly signal goes quiet, check
  `gh workflow list --all` for `disabled_inactivity`.
- **Earlier tag messages lack their `###` headings**: `git tag`'s default
  cleanup strips them as comments. The checklist now passes
  `--cleanup=whitespace`.

## Next

1. Merge the release PR, then tag, publish, verify and create the Release
   page (`CONTRIBUTING.md` § Cutting a release, steps 5–9).
2. Record the new digest here.
3. The `.gitattributes` and AGENTS.md PRs.

Branches: locally, `backup-pre-reset` is a deliberate safety branch — keep
it. `feat/dotnet-11` and `chore/chainguard-regen-dotnet-11` are merged
(rebased) and gone from the remote.
