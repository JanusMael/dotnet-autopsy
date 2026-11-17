# AGENTS.md — `chainguard/`

The Chainguard/Wolfi variant of `dotnet-autopsy-base`, generated from `common/base.dockerfile`.
Additive: the canonical Microsoft-SDK base stays the supported default and the only one the parity
gate covers. The user documentation is `README.md` here.

| File | What it is |
|---|---|
| `generate.sh`, `generate.ps1` | Transform `common/base.dockerfile` into `base.dockerfile`: the Chainguard SDK image, `apt` to `apk`, `USER root`, `DOTNET_EnableEventLog=0` |
| `base.dockerfile` | The generated variant. Committed, so a fresh clone builds without running the generator |
| `build.sh`, `build.ps1` | Build `base.dockerfile` as `dotnet-autopsy-base`; given `sos`, `trace` or `gcdump`, also build that per-case image on it |
| `README.md` | Who the variant is for, how it differs from the canonical base, regenerating, caveats |

## Rules

| Rule | Why | Guarded by |
|---|---|---|
| `base.dockerfile` is never edited by hand; change `common/base.dockerfile` or a generator rule, then regenerate with `./chainguard/generate.sh -y --force` | A hand edit is lost on the next regeneration | the header of `generate.sh` |
| A `chainguard/` change never shares a PR with `common/`, `sos/`, `trace/`, `gcdump/` or the root build scripts | The canonical change lands and is parity-checked first; the regeneration follows on top | `.github/workflows/chainguard-isolation.yml`, a required check |
| `generate.sh` and `generate.ps1` produce the same output, apart from one decorative header line | Either can be the one a maintainer runs | review: diff the two outputs after changing a rule |
| The build wrappers build per-case images themselves and never call the root `build.sh` or `build.ps1` | The root scripts rebuild `dotnet-autopsy-base` from the canonical dockerfile under the same tag, silently replacing the Chainguard base | `build.sh`, `build.ps1` |
| `DOTNET_EnableEventLog` is `0` here and `1` in the canonical base | This image ships `liblttng-ust`; with `1`, `dotnet-sos` segfaults at exit and `RUN dotnet-sos install` fails | generator rule 4 in `generate.sh` and `generate.ps1`; `README.md` § Caveats |
| `ENV DOTNET_ROLL_FORWARD` is inherited from the canonical base, never inserted by the generator | A second insertion duplicates the `ENV` | the generator's `ROLL_FORWARD` note |
| The variant has no `delve-lldb` | `lldb` is not in the free Chainguard and Wolfi feeds | `README.md` § Caveats |

`generate.ps1` names its line list `$outLines`: PowerShell variable names ignore case, and `$out`
would overwrite `$Out`, the output path.
