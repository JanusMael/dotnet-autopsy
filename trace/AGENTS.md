# AGENTS.md — `trace/`

The `dotnet-autopsy-trace` image: a `dotnet-trace` capture (`.nettrace`), analyzed at build time.

| File | What it is |
|---|---|
| `dotnet-trace.dockerfile` | `FROM dotnet-autopsy-base`; bakes the capture, runs `analyze-trace.sh`, runs the in-image smoke under `SMOKE_TEST=1` |
| `analyze-trace.sh` | Build-time analysis: `dotnet-trace report` for top CPU, `dotnet-trace convert --format speedscope` for the flame graph, then `TraceTriage` |
| `TraceTriage/` | The triage app: GC summary, exception histogram and runtime version, read with TraceEvent. Parity-gated |
| `smoke.sh` | Host-side end-to-end smoke on a synthetic capture, through `common/lib/smoke-common.sh` |
| `RUNBOOK.md` | The user's runbook, baked into `/analysis/docs/` |
| `parity/fixtures/`, `parity/golden/` | The triage app's parity corpus |

## Rules

| Rule | Why | Guarded by |
|---|---|---|
| `TraceTriage` is a project, not a file-based app, because it is the one report app with a NuGet dependency (`Microsoft.Diagnostics.Tracing.TraceEvent`) | The BCL-only rule has exactly this exception; a second package needs the same decision | `CONTRIBUTING.md` § Core invariants |
| `TraceTriage` targets the same .NET major as the base SDK image | A mismatch either fails to build in the image or relies on roll-forward for parity output | `TraceTriage/TraceTriage.csproj`; the parity gate in `ci.yml` |
| `dotnet-trace convert -o BASE` writes `BASE.speedscope.json`, appending the suffix itself, so `-o` names the base only | Given the full file name, the suffix doubles and `/analysis/trace.speedscope.json`, the documented URL, is missing | the comment in `analyze-trace.sh`; `RUNBOOK.md` |
| `analyze-trace.sh` exits 0 when a step fails, recording it in the report and `status.json` | The image must still build so the capture stays attachable | the header of `analyze-trace.sh` |
| A new script is added to the `COPY` lists in `dotnet-trace.dockerfile`, as for sos | Missing, it never runs or the in-container reference copy is incomplete | review |
| The smoke's capture is generated in a throwaway SDK container and deleted after it is baked | A capture holds stack samples from a real process | `make_synthetic_input` in `smoke.sh` |

Local `TraceTriage/bin/` and `obj/` are build output, ignored by `.gitignore`.
