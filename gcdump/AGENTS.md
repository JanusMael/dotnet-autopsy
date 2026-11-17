# AGENTS.md — `gcdump/`

The `dotnet-autopsy-gcdump` image: a `dotnet-gcdump` managed-heap snapshot, analyzed at build time.

| File | What it is |
|---|---|
| `dotnet-gcdump.dockerfile` | `FROM dotnet-autopsy-base`; bakes the snapshot, runs `analyze-gcdump.sh`, runs the in-image smoke under `SMOKE_TEST=1` |
| `analyze-gcdump.sh` | Build-time analysis: runs `dotnet-gcdump report`, then `gcdump_triage` |
| `gcdump_triage.cs` | BCL-only file-based app that parses the `dotnet-gcdump report` text into heap summary, top types by size and heuristic warnings. Parity-gated |
| `smoke.sh` | Host-side end-to-end smoke on a synthetic snapshot, through `common/lib/smoke-common.sh` |
| `RUNBOOK.md` | The user's runbook, baked into `/analysis/docs/` |
| `parity/fixtures/`, `parity/golden/` | The triage app's parity corpus |

## Rules

| Rule | Why | Guarded by |
|---|---|---|
| `gcdump_triage.cs` parses text that `dotnet-gcdump` prints, and the tool is unpinned | A change in the tool's output format breaks the triage while the parity gate, which replays committed fixtures, stays green | `rot-check.yml`'s `gcdump` jobs, which run the current tool end to end |
| `analyze-gcdump.sh` exits 0 when a step fails, recording it in the report and `status.json` | The image must still build so the snapshot stays attachable | the header of `analyze-gcdump.sh` |
| A new script is added to the `COPY` lists in `dotnet-gcdump.dockerfile`, as for sos | Missing, it never runs or the in-container reference copy is incomplete | review |
| The smoke's snapshot is generated in a throwaway SDK container and deleted after it is baked | A heap snapshot holds object addresses and type names from a real process | `make_synthetic_input` in `smoke.sh` |

The same holds for `trace/`, whose `dotnet-trace report` output is also parsed as text.
