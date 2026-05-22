# dotnet-trace analysis — unknown / x86_64 — status: unknown

> Rendered view of `analysis.txt`. Authoritative raw source: [analysis.txt](/analysis/analysis.txt) · machine status: [status.json](/analysis/status.json) · [raw markdown](/analysis/analysis.md?raw=1). This file is generated; `analysis.txt` is the source of truth.

<a id="sec-contents"></a>
## Contents

- [Provenance](#sec-provenance)
- [⚠ Analysis degraded](#sec-degraded)

<a id="sec-provenance"></a>
## Provenance
_How this image was built — pin these via --build-arg to reproduce the exact analysis environment._

| Key | Value |
|---|---|
| report_tool | dotnet-trace |
| runtime_version | unknown |
| dump_arch | x86_64 |

<a id="sec-degraded"></a>
## ⚠ Analysis degraded
_The dump could not be fully analyzed — what failed and how to capture a usable one._

> dotnet-trace report/convert reported a failure on the trace.

~~~shell
════════════════════════════════════════════════════════════
  ⚠ ANALYSIS DEGRADED — TRACE FILE UNUSABLE
════════════════════════════════════════════════════════════
  dotnet-trace report/convert reported a failure on the trace.
  Re-capture a cpu-sampling trace at the origin, then rebuild:
    dotnet-trace collect --format nettrace -o trace.nettrace -p <pid>
    dotnet-trace collect --format nettrace -o trace.nettrace -- <command>
  See trace/RUNBOOK.md § Capturing a usable .nettrace.
════════════════════════════════════════════════════════════
~~~
