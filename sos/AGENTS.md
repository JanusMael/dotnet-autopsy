# AGENTS.md — `sos/`

The `dotnet-autopsy-sos` image: a Linux .NET core dump, analyzed with SOS at build time.

| File | What it is |
|---|---|
| `dotnet-sos.dockerfile` | `FROM dotnet-autopsy-base`; bakes the dump, runs `analyze.sh`, runs the in-image smoke under `SMOKE_TEST=1` |
| `analyze.sh` | Build-time analysis through `dotnet-dump analyze`: DAC, exception chain, faulting thread, stacks, heap; writes `analysis.txt`, `status.json` and `provenance.txt` |
| `triage_summary.cs` | BCL-only file-based app that turns the raw SOS output into the triage section. Parity-gated |
| `delve-lldb.sh` | `delve-lldb`: lldb with SOS, anchored on the executable that produced the core |
| `dsos-info.sh` | `dsos-info`: versions of everything baked into the image. Read-only |
| `smoke.sh` | Host-side end-to-end smoke on a synthetic dump, through `common/lib/smoke-common.sh` |
| `RUNBOOK.md` | The user's runbook, baked into `/analysis/docs/` |
| `parity/fixtures/`, `parity/golden/` | The triage app's parity corpus |

## Rules

| Rule | Why | Guarded by |
|---|---|---|
| `analyze.sh` exits 0 even when an SOS step fails, and records the failure in the report and `status.json` | The image must still build so the dump stays attachable for manual work | the header of `analyze.sh` |
| `DUMP_ARCH` matches the dump's architecture, not the host's | The DAC cannot analyze across architectures; a mismatch yields a report with no managed state | `analyze.sh` records `arch_match` in `status.json` |
| The DAC comes from the Microsoft symbol server by the runtime's build ID, cached under `/analysis/symbols` | A DAC from another runtime build produces wrong or partial output, recorded as `status=partial` | `sos_status_assert` in `smoke.sh`, which requires `status=success`, `full-or-triage` fidelity and a DAC from the symbol server or a pre-seeded cache |
| The in-image smoke requires an `OS Thread Id:` row from `clrstack`, not only `dotnet-dump`'s exit code | `dotnet-dump` can exit 0 having analyzed nothing | the `SMOKE_TEST` step in `dotnet-sos.dockerfile` |
| A new script is added to both `COPY` lists in `dotnet-sos.dockerfile`: the one into `/opt/` and the one into `/analysis/docker/` | Missing from the first it never runs; missing from the second the in-container reference copy is incomplete | review |
| The smoke's dump is generated in a throwaway SDK container and deleted after it is baked | A dump is process memory and must never reach the repository | `make_synthetic_input` in `smoke.sh`; `.gitignore` |
| `parity/` stays out of the image | It is host-side test material | `.dockerignore`, `**/parity/` |

User PDBs and app binaries come from `symbols/` (see `symbols/AGENTS.md`).
