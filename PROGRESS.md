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

PRs #1–#7 are all merged.

## In flight: .NET 11 upgrade (plan `plans/00001-dotnet-11.md`)

Branch `feat/dotnet-11`, cut from `docs/progress`; nothing pushed. PR A
carries this file, the plan and the upgrade.

| Step | State |
|---|---|
| 2–6 edits (base, TFMs, CI, scripts, smoke/rot-check/SMOKE_TEST checks, docs) | done, committed on `feat/dotnet-11` |
| 7 parity on SDK 11.0.100 | **passed**, byte-identical for sos/trace/gcdump, apps built `net11.0` |
| 8 smokes + negative test | **passed**: `./smoke.sh all` exits 0. sos: in-image SMOKE_TEST, matched DAC, `status=success`. trace: TOP CPU rows. gcdump: TOP TYPES rows. Negative test rejects `partial` and `fetch-failed` and accepts `success` |
| 9 cross-version (.NET 10 dump on the 11 base) | **passed**: runtime `10.0.12`, `status=success`, DAC from `microsoft_symbol_server` |
| 10 file server starts clean | **passed**: no DataProtection/HTTP_PORTS warnings, `/` → 302 `/analysis`, `RELEASE.txt` = FileServer `2026.11.16` |
| 11 push + PR A | waits for the go-ahead |
| 12 PR B (Chainguard regen) | after A merges |
| 13 release | only on an explicit instruction |

Drift from the plan, decided by the developer on 2026-11-16:

- **PowerShell pinned to 7.6.10** (`ARG POWERSHELL_VERSION`). The unpinned
  global tool resolves to 7.7.0 (published 2026-11-10), which can't be
  installed: its `powershell.linux-x64` 7.7.0 dependency isn't on nuget.org.
  This broke **every** fresh base build, on .NET 10 too, so `main` is
  currently unbuildable until PR A lands. 7.6.10 targets .NET 10 and runs on
  11 via `DOTNET_ROLL_FORWARD=Major`. Unpin once a 7.7.x installs.
- **`sc_status_check` fixed** in `common/lib/smoke-common.sh` (the plan left
  it unchanged), under the standing rule to fix root-caused neighbors and
  flag them. Two pre-existing bugs: (1) it returned 1 whenever the status was
  *not* `failed`, so under `set -e` every passing smoke exited 1 before
  `sc_done`; (2) it passed `/analysis/status.json` as a bare argument, which
  Git Bash rewrites, so on Windows it always read `unknown`. Its strictness
  is unchanged: it still fails only on `failed`.

Family conventions (answer from the Templates session, 2026-11-16; source of
truth in `C:\c\cl\Bennewitz.Ninja.Templates` at `603bdaa`, chiefly
`docs/repository-conventions.md`). dotnet-autopsy isn't a `Bennewitz.Ninja.*`
package repository, so these are candidates for the developer to choose from,
not obligations:

- **Tags**: `vYYYY.Q.MDD` (the month's leading zero dropped), with the
  quarter matching the UTC date. One release per calendar day; no same-day
  patch or fourth part. Precedent for a wrong quarter (Templates
  `2026.3.1001`): leave the tag in place, record it, and let the next correct
  tag supersede it. `v2026.2.902` sorts below every Q3/Q4 tag.
- **AI-facing docs**: `AGENTS.md` at the root and in every top-level
  directory (fact-shaped: no line numbers, dates or counts); `CLAUDE.md`
  beside each, holding only `@AGENTS.md`; `.github/copilot-instructions.md`
  pointing at the root `AGENTS.md`. Shapes in `templates/bbpkg/`.
- **`.gitattributes`**: `* text=auto eol=lf` (or at least `*.md text eol=lf`);
  this would also settle the `*.csproj` CRLF item above.
- **GitHub settings and rulesets**: squash and rebase merges only, with merge
  commits off; delete branches on merge. `main` ruleset: PRs, **0 approvals**,
  conversations resolved, required checks, admin bypass `always`.
  `release-tags` ruleset on `refs/tags/v*`. Recorded in
  `.github/repository.json`.
- **Workflows**: actions pinned by major tag, not SHA; least `permissions`
  per job; a `conventions` job running `repo-conventions.cs check` (that
  enforces some .NET-package-only rules that would need exemptions).
- **Not prescribed**: CHANGELOG (the family uses `PROGRESS.md` plus GitHub
  Releases), CONTRIBUTING, `.editorconfig`, copyright headers. MIT `LICENSE`
  in the template.
- Manual adoption steps: the "Bringing an existing repository in" part of
  `docs/repository-conventions.md`.

Release-time docs (step 13). The developer wants the docs updated for the tag
and release once this is pushed. Release tags (`v2026.x.MDD`) and file-server
package versions (`2026.9.2`) share the CalVer shape, so update them line by
line, never by search-and-replace. As of 2026-11-16 they appear in
`README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `sos/RUNBOOK.md`,
`.github/workflows/publish.yml`, `common/FileServerHost/FileServerHost.csproj`
and `chainguard/` (the last in PR B).

CalVer authority. The developer named the `Bennewitz.Ninja.AutoVersioning`
repository (checkout `C:\c\cl\Bennewitz.Ninja.AutoVersioning`; the copy at
`C:\c\Bennewitz.Ninja.AutoVersioning` is stale) as holding the current CalVer
rules: `YEAR.QUARTER.MMdd`, where QUARTER = `(Month + 2) / 3` and `MMdd` is an
integer (09-02 → `902`). See its `README.md` § Version Format and
`Versioning/AGENTS.md`. This repo's `CONTRIBUTING.md` § Versioning instead
defines the second part as a hand-bumped "series", and must be rewritten to
the quarter rule at release. Under that rule `v2026.2.522` and `.528` are
valid (Q2), but **`v2026.2.902` should have been `v2026.3.902`** (September
is Q3). It is published and signed, so it stays; note the anomaly in
`CHANGELOG.md` rather than moving or deleting it. A release cut on
2026-11-16 would be `v2026.4.1116`.

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

1. Finish plan 00001 steps 8–10, then push PR A on the go-ahead.
2. At release: update the docs for the new tag (see above), and decide
   whether it gets a GitHub Release page.
3. Optionally retune `main`'s protection as above.

Branches: only `main` remains on the remote. Locally, `backup-pre-reset` is a
deliberate safety branch — keep it.
