# Chainguard / Wolfi support for dotnet-autopsy

## Who is this for

You work somewhere that mandates **Chainguard**'s supply chain (Wolfi
base images, signed APKs, distroless production runtimes), and you need
dotnet-autopsy to run on a Chainguard-built image instead of the
Microsoft .NET SDK image.

If you're not in that situation — just use the canonical flow at the
[top-level README](../README.md). It's the supported default and the
parity GOLDEN gate covers it byte-exactly.

## Quick start

> **You do not need to run `generate.sh` first.** The dockerfile it
> produces (`chainguard/base.dockerfile`) is **committed** to the repo,
> so a fresh clone can run `./chainguard/build.sh` immediately.
> `generate.sh` is a *maintenance* tool — see [Two flows](#two-flows-user-vs-maintainer)
> below.

```sh
# Bash / WSL
./chainguard/build.sh              # build the Chainguard base
./chainguard/build.sh sos          # base + sos per-case image
./chainguard/build.sh trace --build-arg TRACE_FILE=mytrace.nettrace
```

```pwsh
# Windows / PowerShell
.\chainguard\build.ps1             # build the Chainguard base
.\chainguard\build.ps1 sos         # base + sos
```

Both wrappers tag the base as `dotnet-autopsy-base` — the same name the
canonical pipeline uses — so the existing root-level `build.sh`,
`demo.sh`, `smoke.sh`, and `docker compose` flows all pick it up
automatically. Once the Chainguard base is built, the per-image flows
are identical to the canonical README's instructions.

## Two flows: user vs maintainer

The Chainguard adaptation lives in two scripts with different audiences:

| You are… | What you run | Why |
|---|---|---|
| **A user / consumer** on a fresh clone | `./chainguard/build.sh` | The dockerfile is committed. `build.sh` reads it, runs `docker build`, produces a local `dotnet-autopsy-base` image. Zero generator step. |
| **A maintainer** after `common/base.dockerfile` changed upstream | `./chainguard/generate.sh -y --force` → review the diff → commit → push | Refreshes `chainguard/base.dockerfile` from the new canonical source. Users on the next clone get the refreshed dockerfile for free. |

Why this split? Same reasoning as the parity goldens being tracked
(see top-level [`README.md` § Parity gate](../README.md#parity-gate-byte-exact-regression-contract)):
**the artifact is the contract**. A reviewer can read
`chainguard/base.dockerfile` directly on a PR; a CI job doesn't have to
run the generator to build; a fresh clone Just Works. The cost is that
maintainers must remember to regen + commit when the canonical changes,
which the chainguard-isolation CI guard reinforces.

```
common/base.dockerfile              ← canonical, hand-edited
       │
       │   maintainers only, when canonical changes:
       │   ./chainguard/generate.sh
       ▼
chainguard/base.dockerfile          ← committed in the repo
       │
       │   the everyday flow — any fresh clone:
       │   ./chainguard/build.sh
       ▼
Local Docker image: dotnet-autopsy-base
```

Nothing is pushed anywhere by either script. Image publishing is a
separate explicit opt-in path — see
[`.github/workflows/publish.yml`](../.github/workflows/publish.yml),
which publishes only the canonical base.

## What you get

- A `dotnet-autopsy-base` image built from
  `cgr.dev/chainguard/dotnet-sdk:latest-dev` instead of Microsoft's SDK
  image. Wolfi/musl userland, distroless-adjacent runtime surface.
- All three per-image flows (`sos`, `trace`, `gcdump`) work unchanged on
  top of it.
- Same .NET diagnostic tools (`dotnet-dump`, `dotnet-gcdump`,
  `dotnet-trace`, `dotnet-sos`, `dotnet-counters`, `dotnet-stack`,
  `dotnet-symbol`, `dotnet-monitor`), same PowerShell 7, same file
  server, same Fresh editor, same `delve` interactive wrapper.

## What's different from canonical

| Aspect | Canonical (`common/base.dockerfile`) | Chainguard (`chainguard/base.dockerfile`) |
|---|---|---|
| Base image | `mcr.microsoft.com/dotnet/sdk:10.0` | `cgr.dev/chainguard/dotnet-sdk:latest-dev` |
| Package manager | `apt-get install` (Debian) | `apk add --no-cache` (Wolfi) |
| User after `FROM` | inherited (root on the Microsoft image) | explicit `USER root` (Chainguard runs nonroot by default) |
| `lldb` availability | yes | **no** — see caveat below |
| `delve` (dotnet-dump wrapper) | works | works |
| `delve-lldb` (lldb wrapper) | works | **unavailable** — lldb absent |
| Per-image dockerfiles | — | unchanged (they `FROM dotnet-autopsy-base`) |

Everything else (the .NET diagnostic tools, the file server, the Fresh
editor, the shared `.cs` apps, the PATH hardening) is byte-identical
because the source is a transformation of the canonical file. Re-run
`./chainguard/generate.sh` whenever `common/base.dockerfile` is
updated upstream to refresh the adaptation.

## Regenerating

The generator produces a **single file**: `chainguard/base.dockerfile`.
The build wrappers (`build.sh`, `build.ps1`) and this README are normal
hand-edited repo files — the generator does not touch them. Edit them
freely; `--force` only affects `base.dockerfile`.

**`chainguard/base.dockerfile` is generated but committed** (not
gitignored). A fresh clone can run `./chainguard/build.sh` immediately
without first running the generator; CI doesn't have to regenerate to
build; PR reviewers see the exact dockerfile that runs. Same reasoning
as the parity goldens being tracked: the artifact *is* the contract.

The contract for maintainers: when `common/base.dockerfile` changes,
re-run the generator and commit the refreshed
`chainguard/base.dockerfile` alongside the upstream change. The
chainguard-isolation CI guard enforces that those two changes don't
travel in the same PR — first land the canonical change (parity gate
re-verifies on its own merits), then a chainguard-only follow-up PR
with the regen.

If `common/base.dockerfile` changes upstream, regenerate the Chainguard
variant by re-running:

```sh
./chainguard/generate.sh                  # interactive
./chainguard/generate.sh -y --force       # CI / unattended
```

Pin by digest with:

```sh
./chainguard/generate.sh \
    --sdk-image 'cgr.dev/chainguard/dotnet-sdk@sha256:<digest>'
```

## Caveats

- **`lldb` is not in the free Chainguard / Wolfi feeds.** Verified
  empirically: `apk search lldb` on `cgr.dev/chainguard/dotnet-sdk:latest-dev`
  with both `apk.cgr.dev/chainguard` and `packages.wolfi.dev/os` added
  returns only `rust-*` packages (matched on description). The generator
  still attempts dynamic discovery for `lldb` / `lldb-N` / `lldb-default`,
  so if Wolfi ever adds it the build picks it up automatically. Until
  then, the **`delve-lldb` wrapper is unavailable on this Chainguard
  variant** and the toolchain smoke logs `INFO: lldb absent …`. The
  primary interactive path (`delve`, which wraps `dotnet-dump analyze`)
  is unaffected and still works. If you have a paid Chainguard
  subscription, append `apk.cgr.dev/extra-packages` to
  `/etc/apk/repositories` in the generated dockerfile — that feed does
  contain `lldb`.
- **`dotnet-monitor`** is the one pinned global tool (default
  `9.0.0`). It targets the .NET 9 runtime, which Chainguard SDK images
  do not ship (the Microsoft SDK image bundles both 9.x and 10.x runtimes
  side-by-side; Chainguard ships only 10.x). The generated dockerfile
  sets `ENV DOTNET_ROLL_FORWARD=Major` immediately after the existing
  `DOTNET_EnableEventLog` env so the .NET host satisfies the 9.x
  framework reference with the available 10.x runtime. To pin a 10-
  native dotnet-monitor instead, pass `--build-arg DOTNET_MONITOR_VERSION=<v>`
  to `./chainguard/build.sh`.
- **Fresh editor** is a static `musl` binary — works on Wolfi
  unchanged.
- **File server** is a self-contained linux-{x64,arm64} binary — works
  on Wolfi unchanged.
- **PATH hardening for login shells** (`/etc/profile.d/dotnet-autopsy.sh`
  + `/root/.bashrc`) is preserved verbatim from the canonical base.
  Chainguard `-dev` images include a `/etc/profile` that sources
  `/etc/profile.d/*.sh`, so the existing snippet Just Works as long
  as the final container runs as root. If you switch to nonroot, also
  write the same PATH snippet to `/home/nonroot/.bashrc` (or to
  `/etc/bash.bashrc` to cover both users).

## What this does NOT replace

- **The parity gate.** The Chainguard image is not byte-parity-tested
  against the canonical one. The parity GOLDEN gate covers the
  Microsoft-SDK base only. Equivalence in this repo is structural
  (same tools, same versions, same scripts), not byte-exact.
- **CI publishing.** The publish workflow (`.github/workflows/publish.yml`)
  publishes only the canonical base to GHCR. The Chainguard variant is
  **not currently published** — see *Why isn't this published?* below.

## Why isn't this published?

Of everything the chainguard flow produces, only one artifact is
*potentially* publishable: the built `dotnet-autopsy-base` (Chainguard
variant) image. Everything else is already shared via git:

- The generator scripts, the dockerfile, and the build wrappers — all
  committed in this directory. Any consumer can `git clone` or `curl`
  the raw GitHub URLs.
- The per-image variants (`sos`, `trace`, `gcdump`) built on top of the
  Chainguard base bake user diagnostic artifacts (process memory, PII)
  and follow the same **never-publish** rule as the canonical
  per-image images.

The Chainguard base image itself is held back from GHCR for now because:

- It carries **known limitations** the canonical doesn't — no `lldb` on
  the free Chainguard / Wolfi feeds (see Caveats above), and the
  `DOTNET_ROLL_FORWARD=Major` shim is needed so `dotnet-monitor 9.0.0`
  can run on Chainguard's .NET 10–only runtime. Publishing implies a
  level of polish the variant doesn't yet have.
- There's **no parity gate** covering it — equivalence with the
  canonical is structural, not byte-exact.
- Chainguard-shop teams typically have **their own internal registries
  and supply-chain procedures**; a public GHCR image would often be
  re-built into a private registry anyway. The committed dockerfile +
  generator give them the substrate to do that.

If you want to publish it yourself — for an internal registry, or a
fork — fork `.github/workflows/publish.yml` and point its
`build-push-action` `file:` input at `chainguard/base.dockerfile`
instead of `common/base.dockerfile`. The cosign + SBOM + SLSA plumbing
all carries over unchanged.

**Future:** if Chainguard adoption demand grows or the limitations
above are addressed (paid Chainguard tier with lldb, or a 10-native
dotnet-monitor that removes the roll-forward shim), the right move is
to extend `publish.yml` with a parallel job that publishes
`ghcr.io/janusmael/dotnet-autopsy-base-chainguard:vX.Y.Z` on the same
tag triggers, with the same multi-arch + cosign + SBOM treatment. Tags
stay in lockstep with the canonical so consumers can pick either
flavor at the same version.

See the top-level `README.md` § *Adapting the base image* for the
manual checklist this script automates.
