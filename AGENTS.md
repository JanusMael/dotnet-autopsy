# AGENTS.md — dotnet-autopsy

> For anyone changing this repository, human or agent. The invariants a change must not break, the
> commands, and the checklists for recurring work. Each top-level directory has an `AGENTS.md` of
> its own for what only its files show. Work state is [`PROGRESS.md`](PROGRESS.md); the developer
> workflow and the release runbook are [`CONTRIBUTING.md`](CONTRIBUTING.md).

## What this repository is

Docker images for post-mortem analysis of .NET diagnostic artifacts. Each per-case image bakes one
captured artifact, analyzes it at build time, then serves the report over HTTP and stays attachable
for interactive work:

| Image | Artifact | Dockerfile |
|---|---|---|
| `dotnet-autopsy-sos` | Linux .NET core dump | `sos/dotnet-sos.dockerfile` |
| `dotnet-autopsy-trace` | `dotnet-trace` capture (`.nettrace`) | `trace/dotnet-trace.dockerfile` |
| `dotnet-autopsy-gcdump` | `dotnet-gcdump` heap snapshot | `gcdump/dotnet-gcdump.dockerfile` |

All three build `FROM dotnet-autopsy-base` (`common/base.dockerfile`): the .NET SDK, the `dotnet-*`
diagnostic tools, the shared report apps and the file server. The base is the only thing
published, to `ghcr.io/janusmael/dotnet-autopsy-base`, by `.github/workflows/publish.yml`.

## Layout

| Directory | What it holds |
|---|---|
| `common/` | The base image, the shared report apps, the shared shell libraries, the file-server host and the parity gate |
| `sos/`, `trace/`, `gcdump/` | One per-case image each: Dockerfile, analyze script, triage app, smoke, runbook, parity corpus |
| `chainguard/` | The generated Chainguard/Wolfi variant of the base, its generator and build wrappers |
| `symbols/` | Where a user drops private PDBs and app binaries for the sos image |
| `plans/` | Numbered plan files |
| `.github/` | The workflows, issue and PR templates, `CODEOWNERS` |

At the root: `build.sh`/`build.ps1` (base, then one per-case image), `smoke.sh` (routes to each
image's smoke), `demo.sh` (a persistent instance for manual checks) and `docker-compose.yml` (the
canonical build-and-run path).

## Invariants

Authoritative text: `CONTRIBUTING.md` § Core invariants.

| Invariant | Failure if broken | Guarded by |
|---|---|---|
| Every report app's output is byte-identical to its committed golden | A report changes meaning without anyone deciding it should | `common/parity/run-parity.sh`; `ci.yml`, the required `Parity gate (…)` checks |
| Report apps are BCL-only; `trace/TraceTriage` (TraceEvent) and `common/FileServerHost` (the file server) are the only NuGet consumers | A new dependency enters the parity contract or the base | review; `CONTRIBUTING.md` § Core invariants |
| No Python anywhere in the images | The base grows a second runtime | review |
| Ports bind to `127.0.0.1:5550`, never `0.0.0.0`, and no `--network host` | Process memory is served unauthenticated to the network | `docker-compose.yml`; `common/lib/smoke-common.sh` and `demo.sh` also bind `127.0.0.1` |
| No dump, trace or gcdump is committed; smoke and demo inputs are generated in throwaway containers and deleted | Process memory, secrets and PII land in git history | `.gitignore`, for `*.dmp` and `*.dump` only; each `smoke.sh`'s `make_synthetic_input`; the PR template's checklist |
| Per-case images are never published | A user's captured artifact reaches a registry | `publish.yml` builds `common/base.dockerfile` only |
| A PR touching `chainguard/` touches no canonical pipeline path | Chainguard drift masks a parity change, or the reverse | `.github/workflows/chainguard-isolation.yml`, a required check |
| Parity fixtures and goldens are never line-ending-normalized | `cmp` fails on a checkout that rewrote them | `.gitattributes`, `-text` on `**/parity/fixtures/**` and `**/parity/golden/**` |
| Releases are tagged `vYYYY.Q.MDD` from the UTC tag date | The tag misstates its date or quarter; a published tag is never moved | `CONTRIBUTING.md` § Versioning |

## Commands

```bash
bash common/parity/run-parity.sh sos        # or trace / gcdump; needs the .NET 11 SDK, no Docker
./build.sh sos                              # base, then the sos image; trace / gcdump likewise
./smoke.sh all                              # build, run, HTTP and in-container checks; self-cleaning
./demo.sh sos                               # leaves a container on 127.0.0.1:5550
docker compose build && docker compose up -d   # the user path, from a ./core.dump
```

- Write `-p:` rather than `/p:`, and run `git show rev:path` with `MSYS_NO_PATHCONV=1`: Git Bash
  on Windows rewrites arguments that look like paths.
- Run anything that passes a regular expression to a CLI from a script file, not inline in Git
  Bash: `cosign verify --certificate-identity-regexp` typed inline fails against a valid signature.

## Checklists

**Changing a report app or an analyze script:** run the parity gate for every image the change
reaches. Drift is a regression until shown otherwise; re-seed with `--seed-golden` only after
checking the new output, and commit the goldens with the code.

**Changing `common/base.dockerfile`:** land it, then regenerate the Chainguard variant in a second
PR (`chainguard/AGENTS.md`).

**Adding a per-case image:** `CONTRIBUTING.md` § Adding a new image sibling.

**Adding a top-level directory:** give it an `AGENTS.md` and a `CLAUDE.md` containing `@AGENTS.md`.

**Releasing:** `CONTRIBUTING.md` § Cutting a release. `main` is protected, so the release commit
lands through a PR and the tag goes on the merged `main`.

**Every change:** update `PROGRESS.md` in the same commit. Commits are Conventional Commits.
